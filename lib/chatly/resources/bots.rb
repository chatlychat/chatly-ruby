# frozen_string_literal: true

module Chatly

  module Resources
    # Bots -- both kinds -- and the delivery ledger an external one produces.
    #
    # `client.bots`
    #
    # Two things share this namespace because the API serves them from one
    # set of routes, and telling them apart is most of what you need to know
    # here:
    #
    #   a **Chatly persona** (`type: "chatly"`) is a prompt, a tool list and
    #   a KB scope that our AI service runs;
    #   an **external agent** (`type: "external"`) is YOUR service: we sign a
    #   payload, POST it to your url, and record the attempt.
    #
    # Routes that only make sense for one kind say so, and they refuse rather
    # than no-op: {#deliveries} is a 404 on a persona (it has no ledger) and
    # {#update_external} is a 400 on one.
    class Bots < Base
      PATH = "/v1/bots"

      # The four delivery states. `failed` will be retried; `dead` will not.
      # A word outside these four on {#deliveries} is a 400, not an empty
      # page.
      DELIVERY_STATUSES = %w[pending delivered failed dead].freeze

      # One page of bots -- `{"items", "nextCursor", "hasMore"}`.
      #
      # The query is the shared cursor set only: `cursor:`, `limit:` (1-100,
      # default 25, and 101 is a 400 rather than a clamp), `sort:`, `fields:`,
      # `filter:`. `sort:` takes `id`, `name`, `createdAt`, `updatedAt`,
      # `status` with a `-` prefix for descending (default `-createdAt`);
      # `filter:` works over `status`, `model`, `templateOrigin`, `createdAt`
      # and `updatedAt`.
      #
      # **There is no `type` filter, and `type` is not a selectable field** --
      # `fields: "type"` is a 400, and any `fields:` at all drops both `type`
      # and `externalAgent` from the rows. So "list my external agents" means
      # paging the whole table and filtering in Ruby.
      #
      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # Every bot, across pages, as a lazy Enumerator.
      #
      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      # One bot, in full.
      #
      # `externalAgent` is nil for a Chatly persona and an object for an
      # external one -- which is the cheapest way to tell the two apart. Its
      # `signingSecretSet` is a BOOLEAN FACT and never the value: no route in
      # this product reads a signing secret back.
      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # Create a bot. Answers 201.
      #
      #   client.bots.create(name: "Support", systemPrompt: "You are...")
      #   client.bots.create(type: "external", name: "Our agent",
      #                      webhookUrl: "https://example.com/chatly")
      #
      # The body is a UNION discriminated by `type:`, and NEITHER member is
      # strict -- so a field from the wrong half is silently dropped rather
      # than refused. For an external agent the fields are FLAT at the top
      # level (`webhookUrl`, `timeoutSeconds`, `fallbackMessage`), not nested
      # under a `config`, even though that is where they are stored.
      #
      # A Chatly persona needs `name:` and a `systemPrompt:` of at least 20
      # characters, and defaults to status `draft`. An external agent needs
      # `name:` and an https `webhookUrl:` that passes our outbound SSRF
      # guard, and defaults to status `active` -- the two branches differ,
      # which is easy to miss.
      #
      # **Two credentials come back exactly once**, on the external branch
      # only: `signingSecret` (we sign, you verify) and `token` (you call us;
      # stored hashed). Neither is ever readable again.
      #
      # And **read `slug` off the response.** Your slug is re-slugified, and a
      # collision is silently de-duplicated with a numeric suffix rather than
      # answered with a 409 -- so the slug you asked for may not be the slug
      # you got.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Patch a bot's OWN fields: `name`, `description`, `systemPrompt`,
      # `model`, `status`, `enabledTools`, `kbScope`, `maxToolCalls`,
      # `guardrails`, `personaMeta`, `escalationRules`.
      #
      # Notably absent: `slug`, `type` and every external-agent field -- those
      # live on {#update_external}. An empty body is a 400 ("No fields to
      # update"), but an unrecognised field is stripped, so sending
      # `webhookUrl` here is a 200 that changed nothing.
      #
      # It also does not check the bot's KIND. Patching a `systemPrompt` on an
      # external agent succeeds and changes nothing observable, because that
      # path never loads a prompt -- the mirror image of {#update_external}
      # refusing a persona outright.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Patch the external-agent half: `webhookUrl`, `timeoutSeconds` (1-60),
      # `fallbackMessage`, `canStartConversations`. All optional, at least one
      # required. A Chatly persona is a 400.
      #
      # It is a read-modify-write of the whole stored config, which is why
      # sending only `canStartConversations:` keeps your url AND your signing
      # secret untouched.
      #
      # Asymmetry with {#create} worth knowing: there `timeoutSeconds`
      # defaults to 15 and `canStartConversations` to false, here omitting
      # either means "leave it alone" -- deliberately, so a partial patch
      # cannot revoke cold-outreach permission by accident.
      def update_external(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}/external", id), merge_body(attributes, kwargs))
      end

      # Mint a new signing secret for an external agent. Answers 201 with
      # `{"signingSecret" => "chsec_..."}` -- that field name, not `secret`
      # and not `token`. No body goes up.
      #
      # **There is no overlap window.** The previous secret stops verifying
      # the instant this returns, so deploy the new one to your verifier
      # first. (Compare `customer_card_endpoints.rotate_secret`, which is
      # deliberately two-phase; these two are not the same pattern.)
      def rotate_external_secret(id)
        http_post(expand("#{PATH}/{id}/external/rotate-secret", id))
      end

      # One page of an external agent's delivery ledger, newest first.
      #
      # **A 404 on a Chatly persona**, deliberately rather than an empty page:
      # a persona has no ledger because nothing is pushed anywhere.
      #
      # `status:` takes one of {DELIVERY_STATUSES} and a fifth word is a 400.
      # `sort:` accepts `createdAt` ONLY -- not `id`, because this table's ids
      # are v4 and so carry no time order. `fields:` and `filter:` are
      # accepted and then ignored.
      #
      # The cursor is a composite of the sort value and the id, so **do not
      # change `sort:` midway through a walk**: a cursor minted under one sort
      # silently restarts at page one. {#auto_deliveries} carries your query
      # through unchanged, which is the safe way to do it.
      #
      # The signed `payload` is NOT on a list row -- a page of fifty would be
      # megabytes of transcript. Use {#delivery} for one.
      #
      # @return [Chatly::Page]
      def deliveries(id, query = {})
        page(expand("#{PATH}/{id}/deliveries", id), query)
      end

      # The whole ledger, across pages, as a lazy Enumerator.
      #
      # @return [Enumerator]
      def auto_deliveries(id, query = {})
        auto(expand("#{PATH}/{id}/deliveries", id), query)
      end

      # One delivery, with `payload` -- the exact bytes that were serialised
      # and signed.
      #
      # Treat the payload as data of its own era: a row written before a key
      # existed carries the shape of the day it was written, which is
      # precisely the row you are reading the log to investigate. It is also
      # scoped to the bot in the path, so one agent cannot read another's
      # deliveries.
      def delivery(id, delivery_id)
        http_get(expand("#{PATH}/{id}/deliveries/{delivery_id}", id, delivery_id))
      end

      # Queue one recorded delivery again, from attempt 0. Answers 201 with
      # `{"queued" => true, "deliveryId", "url"}`.
      #
      # The STORED payload, at the agent's CURRENT url and secret -- so
      # re-pointing the webhook and replaying is a supported repair. The
      # `eventId` is unchanged, which is the point: it is what makes
      # dedupe-by-event-id work across a retry, and therefore a replay of a
      # delivery the receiver already processed is one it will correctly
      # discard. Replay the ones that never arrived.
      #
      # It does not un-ring the fallback. If the delivery went `dead`, the
      # visitor was told and the thread released to a human, that already
      # happened and this does not repeat it.
      def redeliver(id, delivery_id)
        http_post(expand("#{PATH}/{id}/deliveries/{delivery_id}/redeliver", id, delivery_id))
      end

      # Sign a rehearsal payload with the agent's real secret, POST it to its
      # real url, and answer 201 with what came back:
      # `{"ok", "httpStatus", "durationMs", "error", "responseBody", "url",
      # "signature", "payload"}`.
      #
      # SYNCHRONOUS -- it blocks for up to the bot's own `timeoutSeconds` --
      # so a 401 from your own verifier arrives in this response rather than
      # in a log twenty minutes later. `signature` and `payload` come back so
      # you can check a verifier offline against the exact header value and
      # the exact object whose serialisation was signed.
      #
      # It WRITES NOTHING: no ledger row, no conversation, no retry. So it
      # never shows up under {#deliveries}, and calling it a hundred times
      # costs a visitor nothing.
      #
      # `httpStatus` is nil (not 0) when the request never completed, with
      # `ok: false` and `error` set. `responseBody` is echoed on success as
      # well as failure, truncated. The SSRF guard is re-run at call time, so
      # this can refuse a bot that saved cleanly -- DNS changes.
      #
      # The payload carries `test: true` and all-zero UUIDs: acknowledge with
      # a 2xx and do NOT reply, because a reply would target a conversation
      # that does not exist.
      def test_delivery(id)
        http_post(expand("#{PATH}/{id}/test-delivery", id))
      end

      # One bot's numbers: `{"volume", "latency", "reliability", "outcomes"}`
      # plus `botType`, `ledger` and `unit`. It answers for BOTH kinds of bot
      # from one route, reading two different ledgers.
      #
      # The window is `days:` and nothing else -- 1-365, default 30. `from`,
      # `to`, `weeks` and `date` are REFUSED BY NAME with a 400 rather than
      # ignored, which is the kindest thing this API does: a report that
      # stripped `from`/`to` and confidently answered for 30 days is a bug
      # you would never find.
      #
      # Three nullable traps, and in all three null is information:
      #
      #   * a rate is nil, not 0, when its denominator is 0 -- `0` would read
      #     as "nothing failed" about a bot nobody has spoken to. Read
      #     `sampleSize` beside it.
      #   * a nil COUNT means the kind cannot produce that number:
      #     `volume.retrying`, `reliability.fallbackCount` and
      #     `reliability.retriedCount` are nil for a persona (it escalates
      #     rather than retrying), and `volume.cancelled` is nil for an
      #     external agent.
      #   * `latency.basis` says what was timed, and the two values are not
      #     comparable: `last_attempt` is one HTTP round trip to your endpoint
      #     -- the LAST attempt's, since the column is overwritten on retry,
      #     so it is not the sum of three -- while `run_wall_clock` is a whole
      #     tool loop. Latency is percentiles, never a mean.
      #
      # `outcomes.conversations` counts threads this bot TOUCHED, so two bots
      # that shared a thread both count it and per-bot rows do not add up to
      # a workspace total.
      #
      # It needs `reports:read`, not the `triggers:read` the ledger routes
      # want: it returns counts and percentiles with no transcript, payload,
      # conversation id or contact in them.
      def analytics(id, query = {})
        http_get(expand("#{PATH}/{id}/analytics", id), query)
      end
    end
  end
end
