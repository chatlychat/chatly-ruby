# frozen_string_literal: true

module Chatly
  module Resources
    # Aggregated reporting.
    #
    # `client.reports`
    #
    # Every method here takes the same range parameters and none of them is
    # cursor-paginated -- they return rollups, not lists:
    #
    #   days:  how far back to look (the usual default is 30)
    #   from:  ISO-8601 start, when you want an explicit window
    #   to:    ISO-8601 end
    #
    # `business_hours: true` opts the DURATION metrics into the workspace's
    # opening hours. It is per-request and defaults to false, because every
    # figure the product has ever shown is calendar time.
    class Reports < Base
      PATH = "/v1/reports"

      # Headline counters: volume, response times, resolution, CSAT.
      def overview(query = {})
        http_get("#{PATH}/overview", query)
      end

      # Per-agent performance.
      #
      # Note this is `client.reports.agents` -- the REPORT. For the roster of
      # people in the workspace, use `client.workspace.agents`.
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
    end
  end
end
