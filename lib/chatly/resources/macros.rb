# frozen_string_literal: true

module Chatly
  module Resources
    # Macros -- canned replies plus the conversation actions that go with
    # them.
    #
    # `client.macros`
    class Macros < Base
      PATH = "/v1/macros"

      # The macro library visible to this key, as a plain Array.
      #
      # Not paginated, and not pretending to be: the handler is
      # `@PaginationExempt` and answers with a bare JSON array, capped at 200
      # rows and ordered by usage rank. So there is no `Chatly::Page` here, no
      # `nextCursor`, and no `auto_list` -- there is no cursor to walk.
      #
      # @param query [Hash] `scope:` (`"workspace"`, `"team"`, `"personal"`),
      #   `team:` (a team id), `query:` (substring match), `language:`
      # @return [Array<Hash>]
      def list(query = {})
        http_get(PATH, query)
      end

      # One macro by id.
      #
      # The handler parses the id as a UUID before touching the service, so a
      # slug or a malformed id is a 400 here rather than a 404.
      #
      # **A 404 can mean "exists, but not yours to see".** Macros carry
      # forced row-level security with a personal-scope clause, and the
      # current-user setting an API key presents is the KEY's own id -- which
      # matches nobody. So a key reads `workspace`- and `team`-scoped macros
      # and never anyone's `personal` ones, and the refusal arrives as a 404
      # rather than a 403. The same filter applies to {#list}, where it shows
      # up as rows simply not being there.
      def get(id)
        http_get(expand("#{PATH}/{id}", id))
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

      # The macro-action catalogue: every action key a macro may reference.
      #
      # An OBJECT, `{"limit", "actions"}` -- not the bare array the name
      # suggests, so `[0]` on this response is nil. `limit` is the ceiling on
      # actions a single macro may hold, bundled in because a picker offering
      # eleven actions also has to stop the operator at the cap. Each entry
      # names the `permission` its action needs.
      #
      # Worth reading before you write a macro: a macro referencing an action
      # the registry no longer has is a **422** from {#create} and {#update},
      # not a 400 -- it is the only 422 most callers of this API will ever
      # see.
      def actions(query = {})
        http_get("#{PATH}/actions", query)
      end

      # The starter-template catalogue -- `{"items", "total"}`.
      #
      # Also an object, and deliberately NOT a page: there is no `nextCursor`
      # and no `hasMore`, so a client that decodes it as a cursor envelope
      # gets one page and stops. `total` is literally `items.length` over a
      # frozen in-process list -- it is never a hint at a second page.
      #
      # `items` is the LITE shape (a body preview, not the body). Use
      # {#template} for the whole thing.
      def templates(query = {})
        http_get("#{PATH}/templates", query)
      end

      # One template by SLUG, not by id.
      #
      # The handler deliberately does not check the slug against its own
      # enum, so an unknown slug is a 404 from the service rather than a 400
      # -- an earlier version validated first, which made the 404 unreachable
      # and the error less useful.
      #
      # `actions` and `shortCode` are ABSENT rather than nil on most
      # templates, so reach for them with `fetch(key, default)` and not
      # `[key].nil?`.
      def template(slug)
        http_get(expand("#{PATH}/templates/{slug}", slug))
      end
    end
  end
end
