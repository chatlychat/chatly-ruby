# frozen_string_literal: true

module Chatly
  module Resources
    # Customer-data-platform events -- "this person did this thing".
    #
    # `client.events`
    class Events < Base
      PATH = "/v1/cdp/events"

      # Record an event against a contact.
      #
      #   client.events.track(contactId: contact["id"], name: "trial_started",
      #                       properties: { "plan" => "pro", "seats" => 3 })
      #
      # `contactId:` (a UUID v7) and `name:` (1-120 chars) are required;
      # `properties:` is a free-form Hash and defaults to `{}` server-side.
      # Keys inside `properties` are yours and are sent untouched.
      #
      # A write, so it carries an Idempotency-Key. That matters more here
      # than anywhere else: without one, a retried "subscription_cancelled"
      # becomes two in the contact's timeline and two triggers firing.
      def track(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Read back what was tracked, newest first.
      #
      # The same collection {#track} writes to, which is what makes "did my
      # tracking call land?" answerable from code instead of from the
      # dashboard.
      #
      # @param query [Hash] the usual page parameters plus `contactId:` to
      #   scope the stream to one person
      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end
    end
  end
end
