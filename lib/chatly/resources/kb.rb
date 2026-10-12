# frozen_string_literal: true

module Chatly
  module Resources
    # The knowledge base / help centre.
    #
    # `client.kb`
    class Kb < Base
      PATH = "/v1/kb"

      # One page of articles.
      #
      # @return [Chatly::Page]
      def articles(query = {})
        page("#{PATH}/articles", query)
      end

      # Every article, across pages, as a lazy Enumerator.
      #
      # @return [Enumerator]
      def auto_articles(query = {})
        auto("#{PATH}/articles", query)
      end

      # One article by SLUG, not by id.
      #
      #   client.kb.article("how-to-reset-your-password")
      #
      # The slug is percent-encoded into the path for you.
      def article(slug, query = {})
        http_get(expand("#{PATH}/articles/{slug}", slug), query)
      end

      # The collection taxonomy. Not paginated -- a workspace has a handful.
      def collections(query = {})
        http_get("#{PATH}/collections", query)
      end
    end
  end
end
