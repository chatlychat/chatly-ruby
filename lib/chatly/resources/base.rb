# frozen_string_literal: true

module Chatly
  # One class per API namespace. A resource knows a verb and a path and
  # nothing else -- auth, idempotency, retries, error typing and JSON
  # decoding all live in Chatly::Dispatcher, once.
  module Resources
    class Base
      # The client this namespace will call through.
      #
      # Public on purpose. `Client#with_idempotency_key` returns a DERIVED
      # client, and every namespace on it has to point at the derived one or
      # the pinned key is silently ignored for that namespace. The Node SDK
      # shipped exactly that bug -- it rebound four namespaces by hand and
      # forgot `search`. Here the namespaces are rebuilt from one table and
      # the suite asserts `client.equal?(namespace.client)` for all of them,
      # so forgetting one is not possible by construction and is caught if
      # the construction changes.
      attr_reader :client

      def initialize(client)
        @client = client
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      def http_get(path, query = nil)
        @client.request("GET", path, query)
      end

      def http_post(path, body = nil, query: nil, idempotency_key: nil)
        @client.request("POST", path, query, body, idempotency_key: idempotency_key)
      end

      def http_put(path, body = nil, query: nil, idempotency_key: nil)
        @client.request("PUT", path, query, body, idempotency_key: idempotency_key)
      end

      def http_patch(path, body = nil, query: nil, idempotency_key: nil)
        @client.request("PATCH", path, query, body, idempotency_key: idempotency_key)
      end

      def http_delete(path, query: nil, body: nil, idempotency_key: nil)
        @client.request("DELETE", path, query, body, idempotency_key: idempotency_key)
      end

      # One page, wrapped. `Page#raw` is the untouched response.
      def page(path, query)
        Page.new(http_get(path, query))
      end

      # Every page, as a lazy Enumerator of items.
      def auto(path, query)
        Pagination.each_item(query) { |page_query| page(path, page_query) }
      end

      # Fill `{...}` placeholders in a path template, in order, percent-
      # encoding each value as a single path segment.
      #
      # Encoding matters more than it looks: `contacts.remove_tag(id, tag)`
      # puts a customer-chosen tag in the path, and a tag like
      # `needs follow-up` or `50%` would otherwise produce a malformed URL
      # or address the wrong resource. An empty or nil value is an
      # ArgumentError rather than a request to `/v1/contacts//tags`, which
      # the API would answer 404 and leave you guessing.
      def expand(template, *values)
        expected = template.scan(/\{(\w+)\}/).flatten
        if values.length != expected.length
          raise ArgumentError,
                "#{template} takes #{expected.length} path argument(s), got #{values.length}"
        end

        index = -1
        template.gsub(/\{(\w+)\}/) do
          index += 1
          name = expected[index]
          value = values[index]
          if value.nil? || value.to_s.empty?
            raise ArgumentError, "#{self.class.name}: #{name} is required and must not be empty"
          end

          Dispatcher.escape_segment(value)
        end
      end

      # Merge a positional Hash body with keyword arguments, so both of
      # these work and neither wins silently:
      #
      #   client.contacts.upsert(email: "a@b.c")
      #   client.contacts.upsert({ "email" => "a@b.c" })
      #
      # Keyword arguments take precedence on a collision.
      def merge_body(positional, keywords)
        base = positional.nil? ? {} : positional
        unless base.is_a?(Hash)
          raise ArgumentError, "#{self.class.name}: body must be a Hash, got #{base.class}"
        end
        return base if keywords.nil? || keywords.empty?

        base.merge(keywords)
      end
    end
  end
end
