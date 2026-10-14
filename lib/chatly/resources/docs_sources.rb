# frozen_string_literal: true

module Chatly
  module Resources
    # Documentation sources -- someone else's docs, indexed into the KB.
    #
    # `client.docs_sources`
    #
    # The connect flow is three calls in order: {#providers} to render a
    # form, {#discover} to list the spaces a credential can see, then
    # {#create} with one of those spaces. After that {#sync} and {#webhook}
    # keep it fresh.
    #
    # **Every write in this namespace REQUIRES an `Idempotency-Key`** -- the
    # controller declares it class-wide and only the two reads opt out, so
    # even {#discover}, which writes nothing, demands the header. This SDK
    # always sends one; a 428 from here means something stripped it.
    class DocsSources < Base
      PATH = "/v1/docs-sources"

      # The five providers. `website` needs no token (pass `""`), and
      # `discourse` and `website` both need a `baseUrl` -- the schema calls
      # it optional and the service answers 400 without it.
      PROVIDERS = %w[gitbook forumulate discourse readme website].freeze

      # The static provider registry --
      # `{"name", "label", "needsBaseUrl", "needsToken"}` per provider, as a
      # bare Array.
      #
      # Render your connect form from this rather than hardcoding
      # {PROVIDERS}: the flags are what tell you which fields to ask for.
      def providers(query = {})
        http_get("#{PATH}/providers", query)
      end

      # Connected sources, newest first. A bare Array; no query parameters.
      #
      # **Read `syncStatus`, not `articleCount`.** `articleCount: 0` does not
      # mean "synced and found nothing" -- it is also what a queued source
      # looks like. `syncStatus` is the field that answers "did it work":
      # `queued`, `synced`, `synced_empty`, `synced_partial`, `failed`,
      # `paused`. Two of those are SUCCESSES THAT NEED A HUMAN --
      # `synced_empty` and `synced_partial` -- so a caller branching only on
      # `failed` keeps working and learns nothing. Pair it with
      # `unreadableCount`.
      def list(query = {})
        http_get(PATH, query)
      end

      # List the spaces a credential can see, BEFORE connecting one. Answers
      # 201 with a bare Array.
      #
      #   client.docs_sources.discover(provider: "forumulate", token: tok,
      #                                organizationId: org_id)
      #
      # The fields are FLAT -- `provider`, `token`, `baseUrl`,
      # `organizationId` -- with no `credentials` wrapper, which is the shape
      # most people reach for first. `token` is required and `""` is legal: a
      # public Discourse category needs no key, and the sitemap crawler reads
      # only what any visitor can.
      #
      # Pass `organizationId:` when you have one. Without it an org-scoped
      # token cannot list organisations and the whole connect flow fails,
      # while an account-wide token returns every space in every org -- which
      # is how you end up choosing from sixty.
      #
      # An item's `id` and `organizationId` are what {#create} wants as
      # `spaceId:` and `organizationId:`. `itemsUpdatedAt` is nullish -- null
      # or absent, with no difference between them.
      def discover(attributes = {}, **kwargs)
        http_post("#{PATH}/discover", merge_body(attributes, kwargs))
      end

      # Connect a space. Answers 201.
      #
      #   client.docs_sources.create(provider: "gitbook", token: tok,
      #                              organizationId: org, spaceId: space,
      #                              publishOnSync: true)
      #
      # Four required fields, and the names are the trap: `organizationId`
      # (not `orgId`), `spaceId` (not `space`), plus `provider` and `token`.
      # Optional: `label`, `publishOnSync` (not `publish`),
      # `syncIntervalMinutes` (not `interval`; 15-10,080), and
      # `includePaths` / `excludePaths`.
      #
      # The two path filters are **create-only and provider-only**: only
      # `forumulate` and `website` accept them, the other three answer 400,
      # and {#update} cannot change them afterwards. The values you get back
      # are the NORMALISED ones, so they will differ from what you sent;
      # prefixes match at segment boundaries and an exclude beats an include.
      #
      # It does more than insert a row: it verifies the token can actually
      # see `spaceId` (a 400 listing the visible ids if not), creates or
      # claims a KB collection named after the space, and ENQUEUES THE FIRST
      # SYNC before returning. So the response always reads
      # `syncStatus: "queued"`, `articleCount: 0`, `lastSyncedAt: nil` -- that
      # is not a failure, it is a job you have not waited for.
      #
      # No field in any response ever carries the token back.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Patch a source. All fields optional, but send at least `{}` -- the
      # body is parsed, so an absent body is a 400 (this method sends `{}`
      # for you).
      #
      # `status:` accepts only `"active"` and `"paused"`; `"error"` is a
      # read-only state. A successful token rotation clears `lastError`, and
      # so does setting `status: "active"`.
      #
      # A replacement `token:` is VERIFIED against the provider before it is
      # stored, so a token that authenticates but cannot see this source's
      # space is refused and your working credential is left alone.
      #
      # The limits differ from {#create} for no reason worth relying on:
      # `token` is 1-500 here against 400 there, `baseUrl` 500 against 300. A
      # new `baseUrl` is MERGED into the stored config rather than replacing
      # it, which is what keeps `spaceId` alive.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Queue a sync. Answers 201 with `{"queued" => true, "full"}`.
      #
      #   client.docs_sources.sync(id)              # delta
      #   client.docs_sources.sync(id, full: true)  # re-read everything
      #
      # The flag is **`full`** -- not `force`, not `fullSync` -- and it drops
      # the incremental watermark first. It defaults to false, because a
      # scheduled sync has to stay a delta or every space is re-read on every
      # pass.
      #
      # Reach for `full: true` after fixing anything on OUR side of the
      # pipeline. A delta after a reader-side fix correctly finds no upstream
      # changes and leaves the knowledge base exactly as wrong as it was --
      # which is a real incident in this product's history, not a
      # hypothetical.
      #
      # **A 201 here does not prove the source exists.** The checkpoint reset
      # and the enqueue are both unconditional, so any well-formed UUID
      # answers `{"queued" => true}`; there is no 404 on this route.
      def sync(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/sync", id), merge_body(attributes, kwargs))
      end

      # Ask the PROVIDER to start pushing change events to us. Answers 201
      # with `{"subscribed", "reason"}`.
      #
      # **This is a subscribe, not a receiver**, despite the path. The
      # inbound receiver is a different, public, HMAC-verified route that is
      # correctly absent from this SDK -- nothing with an API key should ever
      # call it.
      #
      # **`subscribed: false` with a `reason` is a SUCCESS.** A read-only
      # token cannot manage webhooks at the provider, which is the common
      # case and a fact to report rather than an error to raise; the source
      # keeps polling on its interval. Only one of the five providers
      # publishes change events at all -- check `webhookCapable` on the
      # source rather than assuming.
      #
      # Safe to call twice: an already-subscribed source answers
      # `{"subscribed" => true}` and registers nothing. That guard matters,
      # because the provider's own API has no idempotency and a second POST
      # there would create a second endpoint and deliver everything twice.
      #
      # It needs our public URL configured to build the callback, so a
      # deployment without one answers 400.
      def webhook(id)
        http_post(expand("#{PATH}/{id}/webhook", id))
      end

      # Disconnect a source. **200 with `{"kept" => <count>}`, not a 204.**
      #
      # `kept` is how many articles STAYED BEHIND: nothing is deleted. The
      # rows are re-marked as manual and the collection survives with its
      # source link cleared, so disconnecting is not a way to remove
      # someone's docs from your KB -- delete the articles for that.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
