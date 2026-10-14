# frozen_string_literal: true

module Chatly
  module Resources
    # Channels -- the mediums conversations arrive on (web, email, WhatsApp,
    # SMS, and the rest).
    #
    # `client.channels`
    #
    # A widget can be stood up entirely from code here: create the channel,
    # read the public id for the snippet, set the allowed origins, rotate the
    # identity-verification secret.
    #
    # This class used to say channel writes were impossible from a key --
    # "`channels:write`, which no key-accessible route grants" -- and that was
    # wrong in both halves: the scope is grantable and four write routes
    # accept it. What is genuinely closed is `DELETE /v1/channels/{id}`
    # (irreversible, and attributed to a person) and
    # `GET /v1/channels/{id}/secret` (reveals a credential and leaves no
    # trace). {#rotate_secret} is open INSTEAD of the reveal, which is the
    # trade: you can always get a working secret, never see the current one.
    class Channels < Base
      PATH = "/v1/channels"

      # The 17 types {#create} accepts. Narrower than what a channel RESPONSE
      # may carry -- `telegram_user` exists in the database enum and is
      # readable, but is deliberately not creatable.
      CREATABLE_TYPES = %w[
        web email whatsapp messenger instagram sms voice api telegram
        discord apple line viber slack msteams tiktok twitter
      ].freeze

      # Every channel in the workspace. Not paginated -- there are a handful.
      #
      # Worth reading the `originsRestricted` field on a web channel twice:
      # `false` means the allowed-origins list is EMPTY, which admits any
      # origin. That distinction is invisible in the raw JSON, which is why
      # the API reports it as its own field. It is nil on anything that is
      # not a web channel.
      #
      # `embed` is non-nil only for a web channel and carries `loaderUrl`, the
      # ready-made `snippet`, and the `scriptSrc` / `connectSrc` values a
      # host page's CSP needs.
      def list(query = {})
        http_get(PATH, query)
      end

      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # The channel TYPES this deployment can receive on. A bare Array of
      # STRINGS -- not objects with an id and a label -- sorted and
      # de-duplicated.
      #
      # Not "the channels you have": that is {#list}. This is the registry,
      # and it is what to validate a `type:` against before {#create} rather
      # than hardcoding {CREATABLE_TYPES}.
      def adapters(query = {})
        http_get("#{PATH}/adapters", query)
      end

      # Create a channel. Answers 201.
      #
      #   client.channels.create(type: "web", name: "Marketing site",
      #                          publicId: "acme-web")
      #
      # `type:`, `name:` and `publicId:` are required; the public id is what
      # the embed snippet and the inbound webhook URLs carry. Omitting
      # `brandId:` silently adopts the workspace's DEFAULT brand -- and
      # answers 404 "Default brand" if there is not one, which is a confusing
      # error for a request that never mentioned a brand.
      #
      # **Credential-bearing `config` keys come back as the literal string
      # `"__redacted__"`, on writes as well as reads.** Echoing that value in
      # a later {#update} means "leave this one alone", so a helper that
      # strips or rewrites the marker destroys credentials. Never read a
      # secret off a save response.
      #
      # The response may also carry a provider registration result --
      # `telegramWebhook`, `tiktokWebhook`, `twitterWebhook`, `viberWebhook`
      # or `metaSubscription`, each `{ok:, detail:}` -- for the one provider
      # matching the channel's type. That is the only report you get of
      # whether the webhook registration we performed on your behalf worked.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Patch a channel: `name`, `enabled`, `autoCreateTickets`,
      # `autoAcknowledge`, `acknowledgeTemplate` (nil restores the built-in
      # copy), `acknowledgeSubject`, `config` and `configMode`.
      #
      # **`config` is an RFC 7396 merge by default**: an absent key is left
      # alone and a `nil` value DELETES that key. `configMode: "replace"`
      # overwrites the whole object, which is how you remove several keys at
      # once -- and how you wipe a credential by accident.
      #
      # `type` and `publicId` are NOT patchable; they are stable identifiers
      # and the schema strips them, so sending either is a 200 that changed
      # nothing. A body with no recognised field at all is a **409** ("No
      # fields to update"), not a no-op 200.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Mint a new Chatly-issued channel secret. Answers 201 with
      # `{"secret"}`. No body goes up.
      #
      # **Only `type: "api"` channels have one.** Anything else is a 409 --
      # not a 404, and not a fresh secret. There is no grace window: the old
      # secret stops working the instant this returns.
      #
      # This is the only write in the namespace that does NOT require an
      # `Idempotency-Key` (the handler opts out of the class's requirement).
      # The SDK still sends one, which is harmless -- but do not pin a key
      # here expecting a replay: each call mints a new secret.
      def rotate_secret(id)
        http_post(expand("#{PATH}/{id}/secret/rotate", id))
      end
    end
  end
end
