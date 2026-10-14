# frozen_string_literal: true

module Chatly
  module Resources
    # Triggers -- the rule-based "when X happens, do Y" layer.
    #
    # `client.triggers`
    #
    # A trigger is one event name, a set of conditions and a list of actions.
    # Workflows (the visual DAG) are a different, heavier thing and are not
    # on this surface.
    class Triggers < Base
      PATH = "/v1/triggers"

      # One page of triggers.
      #
      # Genuinely cursor-paginated -- `{"items", "nextCursor", "hasMore"}`,
      # built by the shared paginator.
      #
      # There are no trigger-specific query parameters: narrowing goes
      # through the shared `filter:` as `field:value` or `field:op:value`
      # over `enabled`, `eventType`, `brandId`, `createdAt` and `updatedAt`.
      # `sort:` and `fields:` ARE validated strictly (an unknown column is a
      # 400), but any other unrecognised query key is silently dropped -- so
      # a misspelled filter name is an unfiltered page with a 200, not an
      # error. The default order is `createdAt desc`, never `id`.
      #
      # When you pass `fields:` the rows are PROJECTED, so every field
      # becomes optional on the wire: a row from here is not the whole
      # object.
      #
      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # Every trigger, across pages, as a lazy Enumerator.
      #
      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      # Create OR update a trigger -- it is an upsert, and the manifest's
      # name for it says only half.
      #
      #   client.triggers.create(
      #     name: "Greet pricing-page visitors",
      #     eventType: "conversation.created",
      #     enabled: true,
      #     conditions: [{ field: "page.url", op: "contains", value: "/pricing" }],
      #     actions: [{ type: "send_message", params: { body: "Questions?" } }]
      #   )
      #
      # Passing `id:` takes the UPDATE branch; an `id` that does not exist is
      # a 404 rather than an insert. **Both branches answer 201**, so do not
      # read the status as "created".
      #
      # `enabled:` and `conditions:` are REQUIRED KEYS even though
      # `conditions: []` is legal -- there is no default for either, and
      # omitting them is a 400. `actions:` needs at least one entry (max 20),
      # and its `type` is a closed enum of action names. `conditions` is
      # capped at 50.
      #
      # **`eventType` is a free string on the write side, not an enum**, and
      # it is NOT checked against the catalogue of events that actually have
      # a publisher. A typo therefore saves successfully and produces a rule
      # that never fires -- the most expensive mistake available on this
      # route, and the only one the API will not tell you about.
      #
      # Unknown body keys are stripped rather than rejected, so a snake_case
      # field name is a 201 with that field unset.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Delete a trigger.
      #
      # A HARD delete, and **200 with `{"ok" => true}`, not a 204**. `ok` is
      # a literal, so there is nothing to branch on: a trigger that is not
      # there is a 404, not `ok: false`. A client that assumed an empty body
      # throws away the only acknowledgement it gets.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
