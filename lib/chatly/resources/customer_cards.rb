# frozen_string_literal: true

module Chatly
  module Resources
    # Customer cards -- your own data, rendered in the agent sidebar.
    #
    # `client.customer_cards`
    #
    # A card is a key, a title, a url and a TTL. When an agent opens a
    # conversation we call your url, signed, and render what comes back
    # beside the thread. `contacts.cards` is the READ of the rendered result;
    # this namespace is the configuration.
    #
    # The signing secret has a sibling concept worth reading before you build
    # a verifier: see {Chatly::Resources::CustomerCardEndpoints}, which gives
    # one secret to one URL instead of one per card.
    class CustomerCards < Base
      PATH = "/v1/customer-cards"

      # Cards a workspace may configure. {#create} is a 400 at the ceiling,
      # counted inside the insert, so a race cannot exceed it.
      MAX_CARDS = 25

      # Configured cards. A bare Array, and no query parameters at all.
      #
      # Header NAMES only -- `headerNames` is the keys of the stored bag, so
      # `["Authorization"]` and never the token. No read path in this product
      # returns a card secret or a header value; a lost secret is rotated,
      # not recovered.
      #
      # A card whose header bag cannot be decrypted reads as
      # `headerNames: []` rather than failing the list. That is a real state
      # worth noticing: the card is now calling your endpoint
      # unauthenticated, and the only symptom is a 401 in your own logs.
      def list(query = {})
        http_get(PATH, query)
      end

      # Configure a card. Answers 201 with `{"card", "secret"}`.
      #
      #   client.customer_cards.create(key: "orders", title: "Recent orders",
      #                                url: "https://example.com/chatly/cards",
      #                                ttlSeconds: 300,
      #                                headers: { "Authorization" => "Bearer ..." })
      #
      # **`secret` sits BESIDE `card`, not inside it** -- `{"card" => {...},
      # "secret" => "cc_..."}` -- and this is the only response that carries
      # it. Store it when you get it.
      #
      # The body is `.strict()`, so an unknown key is a 400 rather than a
      # silent strip: one of the few places on this API where a typo is
      # visible. `ttlSeconds:` is REQUIRED (15-31,536,000) and is rejected
      # out of range rather than clamped. `position` is not a create field --
      # the server appends.
      #
      # At most 10 headers, and ten header names are reserved (the
      # `x-chatly-*` signing set plus `content-type`, `accept`, `host`,
      # `content-length`, `user-agent`).
      #
      # A duplicate `key` is a 409 and the 26th card is a 400.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Patch a card. The create body partial, plus `position:` (0-1000),
      # which create does not take. Answers with the BARE card -- not the
      # `{card:, secret:}` envelope create uses.
      #
      # An absent field is left alone; `headers: {}` CLEARS the bag.
      #
      # One asymmetry to be careful with: create answers 409 on a duplicate
      # `key`, and this route has no such guard -- patching `key:` to one
      # another card already owns hits the unique index and surfaces as a
      # 500. Pick a new key, do not move an existing one.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Mint a new signing secret for one card. Answers 201 with
      # `{"secret"}`. No body goes up.
      #
      # **The old secret dies immediately.** There is no pending state and no
      # overlap, so update your verifier first. (The endpoint-level rotation
      # in {Chatly::Resources::CustomerCardEndpoints} is deliberately
      # two-phase instead; do not carry assumptions between the two.)
      def rotate_secret(id)
        http_post(expand("#{PATH}/{id}/rotate-secret", id))
      end

      # Delete a card. **200 with `{"ok" => true}`, not a 204.**
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
