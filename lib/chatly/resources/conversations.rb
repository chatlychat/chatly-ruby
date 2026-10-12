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

      # Threads waiting on a human: the queue an autonomous agent polls.
      #
      # Not cursor-paginated; it answers with a bounded, server-ordered list.
      def unattended(query = {})
        http_get("#{PATH}/unattended", query)
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
    end
  end
end
