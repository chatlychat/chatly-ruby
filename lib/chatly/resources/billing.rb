# frozen_string_literal: true

module Chatly
  module Resources
    # Plans, usage meters and invoices.
    #
    # `client.billing`
    #
    # Reads only. Nothing here starts, changes or cancels a subscription:
    # `POST /v1/billing/checkout-session` and the customer-portal route
    # require a signed-in person with billing permission, and a workspace key
    # is not a person.
    #
    # This is also the one namespace that still answers on a SUSPENDED
    # workspace (the controller is `@AllowWhenSuspended`), because billing is
    # how a workspace stops being suspended.
    class Billing < Base
      PATH = "/v1/billing"

      # The four usage meters, and the closed list {#usage} and {#usage_daily}
      # validate against. An absent, empty or unrecognised value is a 400
      # thrown before anything is read -- not an unfiltered summary.
      EVENT_TYPES = [
        "conversation.opened",
        "message.sent.agent",
        "message.sent.bot",
        "ai.tokens"
      ].freeze

      # The plan catalogue -- what this deployment can actually sell, with
      # limits and prices.
      def plans(query = {})
        http_get("#{PATH}/plans", query)
      end

      # Plan, seats, period and balance in one object.
      #
      # `seatsLimit: -1` means UNCAPPED and is the value on every plan today,
      # so `seatsRemaining: -1` is normal and must not be rendered as a
      # deficit. `stripeConnected: false` is a deployment with no Stripe keys
      # -- the plan is then whatever the operator set, which is a success
      # state and not an error.
      def summary(query = {})
        http_get(PATH, query)
      end

      # Month-to-date usage for ONE meter.
      #
      #   client.billing.usage("message.sent.agent")
      #   client.billing.usage("ai.tokens", from: "2026-10-01T00:00:00Z")
      #
      # **`eventType` is required.** The handler validates it against
      # {EVENT_TYPES} and throws before reading anything, so a call without
      # one is a 400 and never a summary of everything. This method used to
      # take only a query Hash, which made `client.billing.usage` -- the
      # obvious call -- a method that could not succeed; four sibling SDKs
      # shipped the same shape.
      #
      # `from`/`to` are ISO instants and `to` is exclusive; omitted, the
      # window is the current UTC calendar month. `to <= from` is a 400.
      #
      # @param event_type [String] one of {EVENT_TYPES}; may also be passed
      #   as `eventType:` in the query
      def usage(event_type = nil, params = {}, **kwargs)
        http_get("#{PATH}/usage", meter_query("usage", event_type, params, kwargs))
      end

      # The DAILY series for one meter, same mandatory `eventType` gate as
      # {#usage} and the same four values.
      #
      # The series is DENSE: one bucket per UTC day in `[from, to)`, zeros
      # included, so `days.length` is the width of the window rather than the
      # number of days with activity -- never infer a gap from a missing key.
      #
      # The 365-day ceiling is a SILENT TRUNCATION, not a rejection: ask for
      # two years and you get a 200 with 366 buckets and no indication the
      # tail was cut. Window the request yourself if the span matters.
      def usage_daily(event_type = nil, params = {}, **kwargs)
        http_get("#{PATH}/usage/daily", meter_query("usage_daily", event_type, params, kwargs))
      end

      # The monthly rollup -- and it does NOT take an `eventType`.
      #
      # That asymmetry is the thing to know: {#usage} and {#usage_daily}
      # refuse a request without a meter, while this route never reads the
      # parameter and always rolls up all four. Passing it is not an error and
      # not a filter; it is ignored, and you get everything back looking like
      # you asked for it.
      #
      # The one parameter is `month:` as `YYYY-MM` in UTC -- anything else is
      # a 400 from a hand-written parser, and omitting it means the current
      # month. The window is always a whole calendar month regardless of what
      # you pass; `month` only chooses which one.
      #
      # The response carries an `items` key and NO `nextCursor`, so it is an
      # object and not a page -- `items` is always all four meters, zeros
      # included. `total` sums unlike units (conversations + messages +
      # tokens), which makes it a convenience figure rather than a quantity.
      def usage_monthly(query = {})
        http_get("#{PATH}/usage/monthly", query)
      end

      # Stripe invoices, newest first.
      #
      # **Cursor-paginated, but the envelope is `{"data", "nextCursor"}` --
      # `data`, not `items`.** It is the one route on this surface that spells
      # the envelope differently, which is why it is an object here rather
      # than a `Chatly::Page` and why there is no `auto_invoices`: a walker
      # keyed on `items` would read nil and report an empty page forever. Walk
      # it by hand, passing the `nextCursor` you were given back as `cursor:`.
      #
      # The cursor is the previous row's ISO `createdAt`, not an opaque token,
      # and an unparsable one is SILENTLY the first page rather than a 400.
      # `limit` is clamped (1-100, default 25), not rejected: `limit: 5000`
      # quietly becomes 100.
      #
      # Rows mirror Stripe into our own table, so an empty page can mean
      # "Stripe never sent a webhook" rather than "no invoices".
      def invoices(query = {})
        http_get("#{PATH}/invoices", query)
      end

      private

      # `eventType` positionally, or in the query, or an ArgumentError here
      # rather than a 400 from three layers down.
      def meter_query(method, event_type, params, kwargs)
        merged = {}
        params.each { |key, value| merged[key.to_sym] = value }
        kwargs.each { |key, value| merged[key.to_sym] = value }
        type = event_type || merged[:eventType]
        if type.nil? || type.to_s.empty?
          raise ArgumentError,
                "billing.#{method}: eventType is required and must be one of " \
                "#{EVENT_TYPES.join(', ')}"
        end

        # `eventType` first, so the query string reads the way the handler
        # does: it is the one parameter the route refuses to work without.
        { eventType: type }.merge(merged)
      end
    end
  end
end
