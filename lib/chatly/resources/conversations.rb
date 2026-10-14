# frozen_string_literal: true

module Chatly
  module Resources
    # Conversations and the messages inside them.
    #
    # `client.conversations`
    class Conversations < Base
      PATH = "/v1/conversations"

      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # One page of messages in a thread.
      #
      # Read the thread before replying to it. The MCP server has exposed
      # this since it shipped; the Node SDK did not have it for a long time,
      # so "read the conversation, then decide" meant hand-rolling HTTP.
      #
      # @return [Chatly::Page]
      def messages(id, query = {})
        page(expand("#{PATH}/{id}/messages", id), query)
      end

      # @return [Enumerator]
      def auto_messages(id, query = {})
        auto(expand("#{PATH}/{id}/messages", id), query)
      end

      # Post a message into a thread.
      #
      # NAMED `send_message`, NOT `send`. `send` is `Object#send` -- Ruby's
      # own "call this method by name" -- and shadowing it on a public object
      # breaks metaprogramming, serialisers and anything that calls
      # `obj.send(:foo)`. `surface.json` lists the method as `send`; every
      # other language binding uses that name and Ruby cannot.
      #
      #   client.conversations.send_message("0192...", body: "On it!")
      #
      # `body:` is the message text and is the only required field (it may be
      # empty only when the message carries attachments). `kind:` defaults to
      # `"text"` server-side; the other values are `"rich"`, `"note"` (an
      # internal note the contact never sees) and `"system_event"`.
      #
      # Who the message is attributed to is decided by the API from the key:
      # an unlinked API key sends as `system` with no author, and a key bound
      # to a machine user sends as that agent.
      def send_message(conversation_id, attributes = {}, **kwargs)
        http_post(
          expand("#{PATH}/{id}/messages", conversation_id),
          merge_body(attributes, kwargs)
        )
      end

      # Open threads no human agent has replied to yet -- the queue an
      # autonomous agent polls.
      #
      # Cursor-paginated. Narrowing parameters: `assignee:`, `team:`,
      # `channel:`, `olderThanMinutes:`, plus `cursor:` and `limit:`.
      #
      # The envelope carries a `total` beside the page, which is the number
      # waiting rather than the number on this page -- read it off the Page
      # so a backlog of 900 does not read as 25:
      #
      #   queue = client.conversations.unattended(olderThanMinutes: 15)
      #   queue["total"]  # => 912
      #   queue.size      # => 25
      #
      # @return [Chatly::Page]
      def unattended(query = {})
        page("#{PATH}/unattended", query)
      end

      # The whole unattended queue, across pages, as a lazy Enumerator.
      #
      # @return [Enumerator]
      def auto_unattended(query = {})
        auto("#{PATH}/unattended", query)
      end

      # "Do I still own this thread?" -- the handling state and who holds it.
      #
      # A read, guarded on `conversations:read`, so a monitoring key can poll
      # it to discover that a human took the thread over.
      def agent_handling(id)
        http_get(expand("#{PATH}/{id}/agent-handling", id))
      end

      # Report your agent's progress on a thread.
      #
      #   client.conversations.set_agent_handling("0192...", state: "handed_off",
      #                                           reason: "needs a refund")
      #
      # `state:` is required and is one of `"in_progress"`, `"handed_off"` or
      # `"handled"`. `reason:` is optional and only meaningful on
      # `"handed_off"` -- it is what the human who picks the thread up reads.
      #
      # PUT, so it sets rather than toggles: sending the same state twice
      # leaves the thread where you asked for it.
      #
      # This route requires a MACHINE principal. A key that is not bound to a
      # machine user gets a 403 (`Chatly::PermissionError`), and so does a
      # signed-in person -- it is the only pair of routes in the product with
      # that requirement.
      def set_agent_handling(id, attributes = {}, **kwargs)
        http_put(expand("#{PATH}/{id}/agent-handling", id), merge_body(attributes, kwargs))
      end

      # Replies your BYO agent has proposed on this thread, with their
      # approval state.
      def generated_replies(id, query = {})
        http_get(expand("#{PATH}/{id}/generated-replies", id), query)
      end

      # Propose a reply for a human to approve.
      #
      # This is the key-accessible half of the BYO-agent protocol. SENDING an
      # approved reply is deliberately not key-accessible: a key cannot
      # approve its own proposal, which is the entire point of the gate.
      def generate_reply(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/generated-replies", id), merge_body(attributes, kwargs))
      end

      # Messages queued to go out later on this thread.
      def scheduled_messages(id, query = {})
        http_get(expand("#{PATH}/{id}/scheduled-messages", id), query)
      end

      # Queue a message for later.
      #
      #   client.conversations.schedule_message(
      #     "0192...", body: "Checking in!", sendAt: Time.now.utc + 3600
      #   )
      #
      # A `Time` in a BODY is serialised by `JSON.generate`, which does not
      # produce ISO-8601 -- pass `Time#iso8601` or a string. (Query
      # parameters are a different path and ARE converted; see the README.)
      def schedule_message(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/scheduled-messages", id), merge_body(attributes, kwargs))
      end

      # Cancel a queued message.
      #
      # Note the path: scheduled messages are cancelled on a workspace-level
      # collection, not under their conversation, so this takes the SCHEDULED
      # MESSAGE's id and not the conversation's.
      def cancel_scheduled(scheduled_id)
        http_delete(expand("#{PATH}/scheduled-messages/{scheduled_id}", scheduled_id))
      end

      # Report how a conversation ended, so the AI funnels count it. Answers
      # 201.
      #
      #   client.conversations.record_outcome(id, outcome: "resolved")
      #   client.conversations.record_outcome(id, outcome: "escalated",
      #                                       reason: "needs a refund")
      #   client.conversations.record_outcome(id, outcome: "purchased",
      #                                       outcomeRef: "order_8812",
      #                                       valueCents: 4900, currency: "USD")
      #
      # Three words, and each lands somewhere a report already looks:
      # `resolved` files an AI-resolution row with `source: "agent_report"`,
      # the same bucket the visitor's own "this answered" chip lands in;
      # `escalated` is **not a recording but an ACTION** -- the thread moves
      # to `pending`, bot ownership is released, and your `reason` is posted
      # to the receiving human as an internal note (so `reason` is effectively
      # required there, and it is classified into the category the handoff
      # funnel groups on); `purchased` writes a CDP event on the contact,
      # which can complete a conversion goal.
      #
      # The body is strict and has three cross-field rules worth knowing
      # before you build it: `valueCents` and `currency` are REFUSED on
      # anything but `purchased` rather than dropped; `outcomeRef` is
      # REQUIRED on `purchased`; and `currency` is required whenever
      # `valueCents` is.
      #
      # **Chatly has no revenue report.** `valueCents` is stored and summed by
      # nothing. The response's `feeds` field says in words what the outcome
      # actually drives, because the caller cannot see the dashboard.
      #
      # `created: false` beside a 201 is SUCCESS, not a conflict: an equal
      # outcome was already on record -- a replayed resolution, a repeated
      # escalation inside a minute, or a purchase whose `outcomeRef` we
      # already hold. That reference is unique per workspace forever, and it
      # rather than the `Idempotency-Key` is what stops a double-counted
      # purchase across processes.
      #
      # Nothing here CLOSES the conversation. Reporting an outcome is
      # reporting, not finishing.
      #
      # Scopes: `conversations:write` AND `conversations:read`. The second is
      # not implied, and without it every conversation in the workspace
      # answers 404 -- indistinguishable from a wrong id.
      def record_outcome(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/outcomes", id), merge_body(attributes, kwargs))
      end

      # What is already on record for this thread --
      # `{"conversationId", "items"}`.
      #
      # An object that CARRIES `items` and has no cursor, so read `items`
      # yourself rather than pointing a paginator at it. Merged from three
      # tables, newest first, each arm capped server-side at 20.
      #
      # Every row carries `source`, and that is the field to read: it tells
      # your own `agent_report` apart from the visitor's `visitor_chip`, and
      # an escalation a human asked for (`agent_request`) apart from one a bot
      # gave up on (`bot_handoff`). Note `recordId` is non-nil here while the
      # POST can answer with nil -- an escalation hands back no row id.
      def outcomes(id, query = {})
        http_get(expand("#{PATH}/{id}/outcomes", id), query)
      end

      # Hand an open thread back to an assistant, after a human took it.
      # Answers 201 with
      # `{"returned" => true, "conversationId", "botId", "botName", "returnedAt"}`.
      #
      #   client.conversations.return_to_bot(id, bot_id)
      #
      # The reverse of an escalation, and it did not exist until late 2026:
      # handoff was one-directional, so once a person answered one question
      # the assistant was out of that conversation for good.
      #
      # `botId` is REQUIRED and is deliberately not defaulted to whoever owned
      # the thread before -- a thread three assistants have touched has no
      # obvious "the" bot, and guessing wrong means the visitor talks to the
      # returns agent about a size exchange. `client.bots.list` has the
      # choices.
      #
      # It refuses rather than quietly doing nothing: `open` is the only
      # returnable status, so `pending` (a human was summoned and has not
      # finished), `snoozed`, `closed` and `merged` are each a 400 naming the
      # status; a `paused` or `draft` bot is a 400; an unknown bot is a 404;
      # and a thread another bot already owns is a 400 naming that bot rather
      # than a silent transfer. A thread the named bot ALREADY owns is a 201
      # success and a no-op, so two teammates pressing the same button is
      # fine.
      #
      # Scope: `conversations:assign`, higher than `conversations:write`,
      # because this moves a thread to somebody else. Distinct from
      # {#set_agent_handling}, which is a BYO agent reporting on ITSELF.
      def return_to_bot(id, bot_id = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { botId: bot_id }.merge(body) unless bot_id.nil?
        http_post(expand("#{PATH}/{id}/return-to-bot", id), body)
      end

      # Conversations merged into or out of this thread -- `{"items"}`.
      #
      # Another object that carries `items` with no `nextCursor`: any
      # "has items, therefore a page" heuristic reads this wrong, and a
      # paginator over it either stops at one page or walks forever. Take the
      # object.
      #
      # `relation` has exactly two values -- `merged_into` (this thread went
      # into that one) and `merged_from` (that one came into this). And a
      # LINK is indistinguishable from a MERGE except by `mergedAt`: linking
      # two threads as duplicates sets the same pointer without closing
      # anything, so it shows up here with `mergedAt: nil` and
      # `status: "open"`. Note `mergedAt` is the other conversation's
      # `closed_at`, not a merge timestamp, so it is nil whenever that row was
      # never closed.
      #
      # 404 if the named conversation is not visible; `{"items" => []}` if it
      # exists and has no links.
      def linked(id, query = {})
        http_get(expand("#{PATH}/{id}/linked", id), query)
      end

      # The inbox badge numbers: four scalars plus per-inbox, per-team and
      # per-label buckets.
      #
      # **Read this before using it from a key.** Three of the seven figures
      # are per-AGENT, and an API key is not a person: a key's "user id" is
      # the key's own id, which matches no agent anywhere. So `mentions` and
      # `participating` are 0 for every key, forever -- and `unread` is worse
      # than useless rather than merely empty, because with no read-state row
      # to compare against the predicate collapses to "has any contact
      # message at all". That makes `unread` a workspace-wide total dressed
      # as a personal badge, and `unattended`, `byInbox`, `byTeam` and
      # `byLabel` are counted over the same inflated set.
      #
      # It is kept here because it is on the shared SDK surface and it does
      # answer 200 -- but for a key, `conversations.unattended` is the honest
      # queue depth. Use this one from a dashboard session, not a key.
      #
      # The one query parameter is spelled **`brand`** and takes a brand UUID.
      # Not `brandId`: it is read raw with no schema, so `brandId` is neither
      # read nor rejected and you get unscoped counts with a 200. It is also
      # interpolated into SQL as a uuid, so a non-uuid value is a 500 -- cast
      # it yourself.
      #
      # `mentions`, `participating` and `unattended` are SUBSETS of `unread`,
      # so summing them double-counts. `byLabel` is capped at 50 buckets.
      def unread_counts(query = {})
        http_get("#{PATH}/unread-counts", query)
      end

      # Patch rich blocks on a message that has already been delivered.
      # Answers `{"id", "blocks", "body"}`, where `id` is the MESSAGE's.
      #
      #   client.conversations.update_blocks(conversation_id, message_id,
      #                                      patches: [{ id: "status", set: { text: "Shipped" } }])
      #
      # Two path parameters in this order: the CONVERSATION, then the
      # MESSAGE. This is the route the integration that authored a card uses
      # to keep it current -- an order card that says "Processing" when the
      # parcel has shipped.
      #
      # `patches:` is 1-50 entries of `{id:, set:}`, each strict. A patch's
      # `id` is a BLOCK id (resolvable at the top level or inside a grid's
      # cards), not the message's and not the conversation's. `set` is a
      # shallow merge over that block's own fields, re-validated against the
      # block's type afterwards, and it may not carry `type` or `id`.
      #
      # It is all-or-nothing: an unknown block id is a 404 and an invalid
      # MERGED result refuses the whole batch with a 400 rather than applying
      # the rest. A message with no rich blocks is a 400, not a 404.
      #
      # `body` in the response may be unchanged even though `blocks` changed:
      # the plain-text rendition is only re-rendered when the stored body was
      # the rendition of the pre-patch blocks, so an author's hand-written
      # sentence is never overwritten. It publishes `message.updated`, so open
      # widgets and inboxes refresh without a reload.
      #
      # Scopes: `messages:write` AND `conversations:read` -- the second is not
      # implied, and without it this answers 404 for every message.
      def update_blocks(id, message_id, attributes = {}, **kwargs)
        http_patch(
          expand("#{PATH}/{id}/messages/{message_id}/blocks", id, message_id),
          merge_body(attributes, kwargs)
        )
      end
    end
  end
end
