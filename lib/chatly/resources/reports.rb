# frozen_string_literal: true

module Chatly
  module Resources
    # Aggregated reporting.
    #
    # `client.reports`
    #
    # ===== THE WINDOW IS NOT SPELLED THE SAME WAY TWICE =====================
    #
    # This class used to open with "every method here takes the same range
    # parameters". It does not, and believing that is how you read a report
    # for the wrong period and never find out.
    #
    # **No reports route validates its query with a schema.** They read raw
    # strings and clamp with arithmetic, so a misspelled window parameter is
    # not a 400 -- it is silently the DEFAULT window, and the numbers come
    # back looking plausible. There is no schema to misread, either: the
    # parameter simply is not read.
    #
    # Verbatim, per route:
    #
    #   overview, agents, conversations_by_day, sla  days / from / to
    #   attribution        dimension, days (1-90, default 30)
    #   response_times     days  (1-90,  default 30)
    #   sources            days  (1-90,  default  7)   -- not 30
    #   voice              days  (1-365, default 30)   -- not 90
    #   cohorts            weeks (2-26,  default  8)   -- NOT days at all
    #   themes             date  (one batch date)      -- not a range
    #   theme_conversations  nothing at all
    #   teams, labels      days / from / to / group_by / business_hours
    #
    # `group_by` and `business_hours` are SNAKE_CASE on the wire. This gem
    # sends query keys exactly as you write them (see the README's "Shapes"
    # note), so `groupBy:` is not a parameter the API reads -- it is the
    # default granularity with a 200.
    #
    # `days` and `weeks` are CLAMPED silently. An explicit `from`/`to` range
    # is REJECTED instead: the two must be supplied together or it is a 400,
    # `to <= from` is a 400, a span over the route's maximum is a 400, and
    # `group_by: "hour"` over a fortnight is a 400.
    class Reports < Base
      PATH = "/v1/reports"

      # The ten page-context keys {#attribution} will break down on. Unlike
      # every other parameter in this class, an unknown `dimension` is a 400
      # rather than a default -- the handler checks it and throws before
      # querying, so there is no "unrecognised dimension falls back" to lean
      # on.
      ATTRIBUTION_DIMENSIONS = %w[
        utm_source utm_medium utm_campaign utm_content utm_term
        referrer_url page_url_at_open device_type browser os
      ].freeze

      # The granularities {#teams} and {#labels} accept as `group_by`.
      GRANULARITIES = %w[hour day week month].freeze

      # Headline counters: volume, response times, resolution, CSAT.
      def overview(query = {})
        http_get("#{PATH}/overview", query)
      end

      # Per-agent performance.
      #
      # Note this is `client.reports.agents` -- the REPORT. There is no
      # key-accessible roster of the people in a workspace; the nearest thing
      # is `client.workspace.agent_skills`.
      def agents(query = {})
        http_get("#{PATH}/agents", query)
      end

      # A time series, one row per day. The series for a volume chart.
      def conversations_by_day(query = {})
        http_get("#{PATH}/conversations-by-day", query)
      end

      # SLA coverage and attainment, with breaches broken down by policy,
      # team and agent. The breach list inside the response is capped at 200
      # rows by the API.
      def sla(query = {})
        http_get("#{PATH}/sla", query)
      end

      # Where conversations came from, broken down on ONE page-context key.
      #
      #   client.reports.attribution(dimension: "utm_campaign", days: 90)
      #
      # A bare ARRAY of rows, not an envelope. `dimension:` defaults to
      # `utm_source` and must be one of {ATTRIBUTION_DIMENSIONS}; `days:` is
      # clamped 1-90.
      #
      # **Two different rows can arrive with `value: nil`**, and `label` is
      # the discriminator, not `value`: one is the untagged bucket
      # ("(not tagged)") and the other is the folded tail past the row cap
      # ("(other)"). Percentages run 0-100 and include the untagged bucket in
      # the denominator, so they sum to 100 over the window -- there is
      # nothing to page to.
      def attribution(query = {})
        http_get("#{PATH}/attribution", query)
      end

      # The weekly retention grid --
      # `cells` of `{cohortWeek, periodOffset, contactsActive, cohortSize,
      # percentage}`.
      #
      # **The window is `weeks:`, 2-26, default 8. There is no `days`
      # parameter on this route at all**: sending one is not an error and not
      # a window, it is ignored, and you get the default eight weeks back.
      #
      # The response ECHOES the clamped `weeks` it actually used, which may
      # not be what you asked for -- label an axis from the response, never
      # from the request.
      def cohorts(query = {})
        http_get("#{PATH}/cohorts", query)
      end

      # Response-time distribution. `days:` 1-90, default 30.
      #
      # Percentiles are SECONDS and are nil -- not 0 -- when `sampleSize` is
      # 0. Zero would read as "we answer instantly".
      #
      # It embeds a `byDay` array of exactly the shape
      # {#conversations_by_day} returns BARE, which is a tempting place to
      # share a decoder and the wrong one: that route answers with the array
      # itself, this one wraps it.
      def response_times(query = {})
        http_get("#{PATH}/response-times", query)
      end

      # Per-channel volume. A bare Array of channel rows.
      #
      # `days:` is 1-90 with a default of **7**, not the 30 every sibling
      # uses -- so the unqualified call here answers for a different period
      # than the unqualified call anywhere else in this class.
      def sources(query = {})
        http_get("#{PATH}/sources", query)
      end

      # Per-team rollup. One of the only two routes that takes
      # `from`/`to`/`group_by`.
      #
      #   client.reports.teams(from: "2026-09-01", to: "2026-10-01", group_by: "week")
      #
      # `rows` includes a `teamId: nil` row -- the unassigned bucket -- which
      # is a real figure and not a null to filter out.
      #
      # `businessHours` comes back as
      # `{requested, applied, reason, tz, sampleTruncated}` and **the figures
      # are never zeroed or relabelled when `applied` is false**: they are
      # calendar time, so read the flag before captioning them. `reason` says
      # why (`disabled`, `not_configured`, `always_closed`,
      # `invalid_timezone`).
      #
      # This route validates `group_by` -- including refusing hourly
      # granularity over a fortnight -- and then has no granularity field in
      # its response. {#labels} echoes one.
      def teams(query = {})
        http_get("#{PATH}/teams", query)
      end

      # Per-label rollup, same window parameters as {#teams}.
      #
      # `rows` is capped at the **50 busiest labels** with the remainder
      # folded into `otherLabels`, and `trend` covers the **top 8 only**,
      # keyed by label NAME rather than id. There is no cursor to the tail: if
      # you need the 51st label, narrow the window or filter conversations
      # directly.
      def labels(query = {})
        http_get("#{PATH}/labels", query)
      end

      # The latest clustered-themes batch.
      #
      # The only window here is **`date:`**, and it selects ONE batch date
      # (`YYYY-MM-DD`) rather than a range -- omit it for the newest batch.
      # `days`, `from` and `to` are not read on this route.
      #
      # **Validate `date` yourself.** It is unvalidated here and reaches a
      # Postgres `date` column raw, so `date: "last-tuesday"` is a 500 rather
      # than a 400.
      #
      # `batchDate` is nil with `themes: []` when no batch exists, which is
      # the normal state for a young workspace. The route resolves the newest
      # batch date and then reads only that batch, so it never mixes two
      # snapshots. Theme rows omit their conversation ids -- that is what
      # {#theme_conversations} is for.
      def themes(query = {})
        http_get("#{PATH}/themes", query)
      end

      # The conversation ids in one theme -- `{"conversationIds" => [...]}`.
      #
      # `id` is a THEME id, not a conversation id. The route takes no query
      # parameters at all: no cursor, no limit, and the batch's own cap is
      # the only bound.
      #
      # An unknown or purged theme answers 200 with an empty list, never a
      # 404 -- so "this theme is empty" and "this theme no longer exists" are
      # the same answer here.
      def theme_conversations(id)
        http_get(expand("#{PATH}/themes/{id}/conversations", id))
      end

      # Voice calls: volume, answer and abandon rates, per-hour buckets and
      # recording storage.
      #
      # `days:` is 1-365 here where the sibling rollups cap at 90.
      #
      # `answerRate` and `abandonRate` are FRACTIONS (0-1), not percentages,
      # and are nil rather than 0 when there were no calls.
      #
      # `recordingStorage.exact: false` means `totalBytesUpperBound` is part
      # measured and part extrapolated from bitrate over `unmeasuredCalls` --
      # bill against `measuredBytes`, not the bound. And `byHour[].weekday` is
      # 0 = Sunday in **UTC**, not in the workspace's timezone, so a
      # "quietest hour" read off this needs converting first.
      def voice(query = {})
        http_get("#{PATH}/voice", query)
      end
    end
  end
end
