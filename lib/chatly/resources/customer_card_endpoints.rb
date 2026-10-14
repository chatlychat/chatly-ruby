# frozen_string_literal: true

module Chatly
  module Resources
    # One signing secret per card URL, instead of one per card.
    #
    # `client.customer_card_endpoints`
    #
    # Why this exists: a single card request carries SEVERAL cards, because
    # Chatly batches the ones sharing a url and headers. Before this, such a
    # request was signed with one of their per-card secrets and named which
    # in `x-chatly-card-id` -- so a receiver serving six cards had to hold six
    # secrets and select by that header, and could not predict which it would
    # need, since a card still in our cache is absent from the request and
    # the signer therefore changed with the cache.
    #
    # Give the URL its own secret and all of that goes away: one secret,
    # verified once per request, `x-chatly-secret-scope: endpoint` on the
    # wire, and no `x-chatly-card-id` at all.
    #
    # **The per-card secret still works.** It is the documented fallback for
    # any url with no endpoint secret, so an existing integration keeps
    # verifying untouched -- but an endpoint secret takes precedence the
    # moment {#create} returns, which is why you deploy it first.
    #
    # The prefixes are not interchangeable: a card secret is `cc_`, an
    # endpoint secret is `cce_`.
    class CustomerCardEndpoints < Base
      PATH = "/v1/customer-card-endpoints"

      # Every endpoint secret, as a bare Array. No query parameters.
      #
      # Read `cardKeys`: it is the cards pointing at each url, and an EMPTY
      # one means that secret signs nothing -- the only way to spot a url you
      # re-pointed or whose cards you deleted.
      #
      # Never a secret, a prefix of one, or a hash: a pending rotation shows
      # as `pendingSecretSet: true`, and `pendingSecretMintedAt` is NOT an
      # expiry -- a pending secret never retires itself.
      def list(query = {})
        http_get(PATH, query)
      end

      # Give one card url its own secret. Answers 201 with
      # `{"endpoint", "secret"}`.
      #
      #   client.customer_card_endpoints.create("https://example.com/chatly/cards")
      #
      # **Deploy the secret to your endpoint BEFORE calling this**: from the
      # moment it returns, every request to that url is signed with it.
      #
      # The url is compared BYTE FOR BYTE against your configured cards'
      # urls, trailing slash included, and a url no card uses is a 400 that
      # lists the urls that do -- deliberately, because without that check a
      # trailing-slash typo would answer 201 with a secret that silently
      # never signs anything. A url that already has an endpoint is a 409;
      # rotate it instead.
      #
      # The body is `.strict()` and `url` is its only field.
      def create(url = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { url: url }.merge(body) unless url.nil?
        http_post(PATH, body)
      end

      # Mint the NEXT secret. Answers 201 with `{"secret", "active" => false}`.
      #
      # **It signs nothing yet.** The current secret keeps signing until
      # {#activate_secret}, and `active: false` is a literal in the schema
      # precisely so a caller reading only `secret` can see that.
      #
      # That two-step IS the overlap window, and it is an ORDER OF OPERATIONS
      # rather than a span of time: Chatly emits one signature per request,
      # so there is nothing a time window could overlap. Mint, deploy,
      # activate.
      #
      # Calling this again before activating REPLACES the pending secret
      # rather than erroring -- so the last one you minted is the only one
      # that will ever go live.
      def rotate_secret(id)
        http_post(expand("#{PATH}/{id}/rotate-secret", id))
      end

      # Promote the pending secret. Answers 201 with `{"activated" => true}`.
      #
      # From here it is the only secret that signs and the previous one is
      # gone, with no undo. A second call is a 409 ("no pending secret") --
      # this route is deliberately not idempotent in its result, because
      # "activate whatever is pending" twice would be a different request
      # the second time.
      def activate_secret(id)
        http_post(expand("#{PATH}/{id}/activate-secret", id))
      end

      # Remove the endpoint secret. **200 with `{"ok" => true}`.**
      #
      # A change at your verifier, not a cleanup: signing for that url
      # reverts to the leading card's own `cc_` secret, and
      # `x-chatly-card-id` comes back on the request.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
