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

      # The conversations a ticket covers. A bare Array.
      #
      # `subject`, `status` and `channelType` are NULLABLE: the join is a
      # left one, so a link whose conversation was hard-deleted still yields
      # a row with those three empty.
      #
      # Two quiet behaviours. Rows are filtered by the per-inbox ceiling with
      # no truncation flag, so a key that cannot see a restricted inbox gets
      # a SHORT array and nothing saying so. And the order is "origin first"
      # with no secondary sort, so ties come back in whatever order the
      # planner chose -- sort in Ruby if it matters.
      #
      # An unknown ticket answers 200 with an empty Array here, where
      # {#status_history} and {#lineage} answer 404. The five ticket reads
      # disagree about missing tickets on purpose; do not write one shared
      # not-found path for them.
      def conversations(id, query = {})
        http_get(expand("#{PATH}/{id}/conversations", id), query)
      end

      # Splits and follow-ups in both directions -- where this ticket came
      # from and what came out of it.
      #
      # Each list is capped at 25. A ticket that is not visible is a 404
      # (explicitly, so that row-level security returning no rows cannot read
      # as "no lineage").
      def lineage(id, query = {})
        http_get(expand("#{PATH}/{id}/lineage", id), query)
      end

      # Status transitions, oldest first.
      #
      # An OBJECT, not an Array:
      # `{"ticketId", "status", "currentStatusForSeconds", "items",
      # "truncated"}`. The three siblings are not derivable from the rows --
      # `status` comes from the ticket itself, not from the last transition --
      # and `truncated` is what distinguishes a capped timeline from a short
      # one. There is no cursor, so beyond the cap the rest is simply not
      # fetchable.
      def status_history(id, query = {})
        http_get(expand("#{PATH}/{id}/status-history", id), query)
      end

      # Logged time -- `{"items", "totalMinutes", "billableMinutes"}`.
      #
      # Another `items` with no `nextCursor`: an object, not a page, and with
      # no row limit either. Both totals are computed server-side, and
      # `billableMinutes` is the subset flagged billable rather than a
      # rounding of the first.
      #
      # **This route never checks that the ticket exists or is yours.** An
      # unknown, foreign or invisible ticket id answers 200 with
      # `{"items" => [], "totalMinutes" => 0, "billableMinutes" => 0}` -- so
      # zero here means "nothing logged OR no such ticket", and you cannot
      # tell which from this call.
      def time(id, query = {})
        http_get(expand("#{PATH}/{id}/time", id), query)
      end

      # How many open tickets a CONVERSATION has -- `{"openTickets" => n}`.
      #
      # The path parameter is a conversation id, not a ticket id and not a
      # queue id, which the route's shape invites you to assume. A
      # conversation the key cannot see raises rather than answering 0.
      #
      # This is the pre-flight call before auto-creating a ticket from a
      # chat: it is how you avoid filing a second one for a thread that
      # already has an open ticket.
      def open_count(conversation_id)
        http_get(expand("#{PATH}/open-count/{conversation_id}", conversation_id))
      end
    end
  end
end
