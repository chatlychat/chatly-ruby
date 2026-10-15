# frozen_string_literal: true

module Chatly
  module Resources
    # Visitors -- opening a conversation with someone who has not written yet.
    #
    # `client.visitors`
    #
    # ONE method, and the other two routes on the controller are absent on
    # purpose. `GET /v1/visitors/live` (who is on the site right now) and
    # `GET /v1/visitors/{contactId}/pages` (their recent page views) carry no
    # `@AllowApiKey()`, so a `ck_` key gets a 403 from both. Shipping a method
    # that always fails is worse than not shipping one: the failure arrives at
    # runtime, in production, in somebody else's integration. Reach them with
    # a signed-in session, from the dashboard, not from here.
    class Visitors < Base
      PATH = "/v1/visitors"

      # Open a conversation with a contact who did NOT write first, and send
      # the workspace's proactive greeting into it. Answers
      # `{"conversationId"}`. No body goes up -- the contact id is the whole
      # input.
      #
      #   client.visitors.start_conversation(contact_id)["conversationId"]
      #
      # == A 403 here is probably not your scopes
      #
      # This is OFF BY DEFAULT, per workspace. The flag is
      # `settings.proactiveOutreach.apiKeysMayStartConversations`; an owner or
      # admin turns it on with `PATCH /v1/workspace/settings`, which needs a
      # signed-in person and so is not reachable from this gem, and you can
      # read the current value with {Workspace#settings}, which is.
      #
      #   client.workspace.settings["proactiveOutreach"]
      #   # => {"apiKeysMayStartConversations" => false}
      #
      # So a `Chatly::PermissionError` from this method means one of two quite
      # different things and the setting is the likelier. `conversations:write`
      # was already grantable and is already held by keys minted for ticket
      # bulk actions and schedule-send, so opening this route on the
      # permission alone would have handed cold outreach to credentials nobody
      # re-reviewed. Check the workspace setting before you go looking at your
      # key's scopes.
      #
      # == The other two things to know
      #
      # **Three per CONTACT per hour**, counted per workspace in Redis rather
      # than per caller -- the abuse shape is N threads at one person, which a
      # per-caller limit cannot see. The fourth call inside the hour is a
      # `Chatly::RateLimitError`.
      #
      # This route can produce TWO different 429s and they do not look alike
      # on the wire:
      #
      #   * the per-contact limit above throws `RateLimitedError(ttl)` from
      #     `consumePerContactOutreachToken`, and the exception filter sends
      #     **no `Retry-After` header at all** -- the TTL arrives only in the
      #     body, at `error.details.retryAfterSeconds`. `#retry_after` is
      #     still populated here, because this gem's error builder falls back
      #     to that field (see the README's note on it); a client that reads
      #     the header alone gets nil and has nothing to wait on.
      #   * the global throttler buckets this route inherits (`short`, 30/s;
      #     `login`, 100/15min) DO produce a `Retry-After`, synthesised in
      #     `main.ts` from the per-bucket headers `@nestjs/throttler` emits.
      #
      # Either way read `#retry_after` rather than the header, and treat nil
      # as "the server did not say" rather than as zero.
      #
      # **An offline visitor is not notified.** The greeting is persisted and
      # the widget renders it from history on their next page view: no email,
      # no push, no provider message, and nothing queued or dropped. An
      # integration that has to reach someone who has left the site wants an
      # email or SMS conversation instead.
      #
      # Unlike {Channels#rotate_secret}, this route does REQUIRE an
      # `Idempotency-Key` -- the controller declares `@RequireIdempotencyKey()`
      # at class level and this handler does not opt out, so a call without one
      # is a 428 in production. The gem always sends one; pin it with
      # {Client#with_idempotency_key} if a retry of the same outreach should
      # replay rather than open a second thread.
      def start_conversation(id)
        http_post(expand("#{PATH}/{contactId}/start-conversation", id))
      end
    end
  end
end
