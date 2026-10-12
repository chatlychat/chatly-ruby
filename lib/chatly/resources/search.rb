# frozen_string_literal: true

module Chatly
  module Resources
    # Full-text search across contacts, conversations, messages, tickets and
    # KB articles.
    #
    # `client.search`
    class Search < Base
      PATH = "/v1/search"

      # Search everything the key can read. One page.
      #
      #   results = client.search.query("refund not received", limit: 10)
      #   results.items        # => the hits
      #   results["facets"]    # => {"conversation" => 12, "ticket" => 3, ...}
      #   results["tier"]      # => "postgres"
      #   results.next_cursor
      #
      # **This returns the whole envelope, not just the hits.** The response
      # carries two things beside `items`: `facets`, the per-entity totals for
      # the query IGNORING the `kinds` filter (so a UI can render tabs with
      # counts that do not vanish when you click one), and `tier`, which
      # backend produced the page (`"postgres"` or `"opensearch"`). A
      # paginator that yielded only hits would throw both away, which is why
      # the single-page form is a `Chatly::Page` with `[]` over the envelope
      # rather than a bare Array of hits.
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
      # @return [Chatly::Page]
      def query(q, params = {}, **kwargs)
        page(PATH, query_for(q, params, kwargs))
      end

      # Every hit, across pages, as a lazy Enumerator.
      #
      # This one yields HITS, not pages -- which is the right shape inside a
      # loop and is also why it is not the only form offered: `facets` and
      # `tier` describe the whole result set, not a hit, so a caller who
      # needs them wants {#query}. The cursor is `rank|createdAt|id` from the
      # last row of the previous page, base64url-encoded; it is opaque, and
      # the rank ties that make it necessary are exactly why you must not try
      # to build one.
      #
      #   client.search.auto_query("refund").lazy
      #         .select { |hit| hit["kind"] == "ticket" }.first(5)
      #
      # @return [Enumerator]
      def auto_query(q, params = {}, **kwargs)
        auto(PATH, query_for(q, params, kwargs))
      end

      private

      def query_for(q, params, kwargs)
        if q.nil? || q.to_s.empty?
          raise ArgumentError, "search.query: q is required and must not be empty"
        end

        { q: q }.merge(params).merge(kwargs)
      end
    end
  end
end
