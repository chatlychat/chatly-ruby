# frozen_string_literal: true

module Chatly
  module Resources
    # Macros -- canned replies plus the conversation actions that go with
    # them.
    #
    # `client.macros`
    class Macros < Base
      PATH = "/v1/macros"

      # The macro library visible to this key.
      #
      # Honest note on paging: `surface.json` marks this endpoint paged, and
      # the API does not page it -- the route is pagination-exempt and
      # answers with a bare JSON array, capped at 200 rows and ordered by
      # usage rank. `Chatly::Page` accepts an array as a single cursorless
      # page, so this returns a `Page` like every other `list` and
      # `next_cursor` is always nil.
      #
      # @param query [Hash] `scope:` (`"workspace"`, `"team"`, `"personal"`),
      #   `team:` (a team id), `query:` (substring match), `language:`
      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # One page, and there is only ever one -- see {#list}. Here for
      # surface parity, and harmless: it yields every row and stops.
      #
      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      # Create a macro.
      #
      #   client.macros.create(name: "Refund issued", scope: "workspace",
      #                        body: "Your refund is on its way.",
      #                        shortCode: "refund")
      #
      # `name:` and `scope:` are required, and a macro needs reply text, at
      # least one action, or both -- `{name:, scope:}` alone is a 422.
      # `teamId:` is required when `scope:` is `"team"`.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Update a macro. PATCH, so omitted fields are left alone.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Delete a macro.
      #
      # Key-accessible because removing a canned reply removes an option,
      # not a conversation.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
