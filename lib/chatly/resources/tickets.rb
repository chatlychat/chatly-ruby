# frozen_string_literal: true

module Chatly
  module Resources
    # Tickets -- the help-desk side of the product.
    #
    # `client.tickets`
    class Tickets < Base
      PATH = "/v1/tickets"

      # Largest selection a single `bulk` call may act on, matching the API.
      BULK_MAX_IDS = 200

      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      # Comments on one ticket, public replies and internal notes alike.
      #
      # Not cursor-paginated -- the API answers with the ticket's thread.
      def comments(id, query = {})
        http_get(expand("#{PATH}/{id}/comments", id), query)
      end

      # The ticket (or tickets) raised from a conversation.
      #
      # Takes the CONVERSATION id, not a ticket id. This is the lookup an
      # integration needs after a chat ends: "did this turn into a ticket?"
      def for_conversation(conversation_id, query = {})
        http_get(expand("#{PATH}/for-conversation/{conversation_id}", conversation_id), query)
      end

      # The workspace's ticket queues.
      #
      # A read-only listing here: creating and editing a queue is not
      # key-accessible, so this exists to resolve a queue name to the id that
      # `bulk(action: "queue")` needs.
      def queues(query = {})
        http_get("#{PATH}/queues", query)
      end

      # Merge `loser_id` into `id`.
      #
      # The ticket in the PATH survives. The one in the body keeps its row
      # and moves to status `merged`, so nothing is destroyed -- but there is
      # no unmerge.
      #
      #   client.tickets.merge(survivor_id, duplicate_id)
      def merge(id, loser_id = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { loserId: loser_id }.merge(body) unless loser_id.nil?
        http_post(expand("#{PATH}/{id}/merge", id), body)
      end

      # Split one ticket into two: the path id is the ORIGIN, and the new
      # ticket is described by the body.
      #
      #   client.tickets.split(origin_id, title: "Billing half of #4812",
      #                        priority: "high")
      #
      # `title:` is required -- a split exists because one report was two
      # problems, and two tickets with the same title are indistinguishable
      # in a queue. `description`, `priority`, `type`, `assigneeUserId` and
      # `tags` are optional and inherit the origin's values when omitted.
      #
      # Unlike `merge`, this CREATES a ticket. Retrying it without a pinned
      # Idempotency-Key is how you get two children -- see
      # `Client#with_idempotency_key`. There is no unsplit.
      def split(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/split", id), merge_body(attributes, kwargs))
      end

      # Act on up to {BULK_MAX_IDS} tickets at once.
      #
      #   client.tickets.bulk(ids: ids, action: "status",
      #                       payload: { status: "closed" })
      #
      # `action:` is one of `"status"`, `"assign"`, `"priority"` or
      # `"queue"`, and `payload:` carries the value that action needs:
      # `status`, `assigneeUserId` (null to unassign), `priority`, or
      # `queueId` (null to remove from its queue).
      def bulk(attributes = {}, **kwargs)
        http_post("#{PATH}/bulk", merge_body(attributes, kwargs))
      end
    end
  end
end
