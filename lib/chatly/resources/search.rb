# frozen_string_literal: true

module Chatly
  module Resources
    # Full-text search across contacts, conversations, messages, tickets and
    # KB articles.
    #
    # `client.search`
    class Search < Base
      PATH = "/v1/search"

      # Search everything the key can read.
      #
      #   client.search.query("refund not received", limit: 10)
      #
      # `q` is required (1-256 characters). Other accepted parameters:
      # `kinds` (an Array; see below), `from` / `to` (ISO-8601),
      # `channelId`, `assigneeUserId`, `status`, `limit` (1-100, default 25)
      # and `cursor`.
      #
      # Narrowing by `kinds` is deliberately not wrapped in a convenience
      # method ("search the KB only"), because the wire spelling that would
      # need is not one this SDK can verify offline. The route's validator
      # declares `kinds` as a plain ARRAY parameter, and this API's query
      # parser only folds a BRACKETED key into a plain one for `filter[]` --
      # so `kinds[]=kb` is dropped on the floor and the search comes back
      # unnarrowed, with a 200 and no warning. Pass the parameter yourself
      # and this SDK repeats the key for each element:
      #
      #   client.search.query("password reset", kinds: %w[kb article])
      #   # => ?q=password%20reset&kinds=kb&kinds=article
      #
      # @return [Hash] the decoded response
      def query(q, params = {}, **kwargs)
        if q.nil? || q.to_s.empty?
          raise ArgumentError, "search.query: q is required and must not be empty"
        end

        http_get(PATH, { q: q }.merge(params).merge(kwargs))
      end
    end
  end
end
