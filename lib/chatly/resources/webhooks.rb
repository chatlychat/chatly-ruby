# frozen_string_literal: true

module Chatly
  module Resources
    # Webhook delivery history.
    #
    # `client.webhooks`
    #
    # This is the DELIVERY LOG, not the endpoint registry: creating and
    # editing webhook endpoints is not key-accessible, so it is not here.
    # For verifying an inbound delivery's signature see
    # `Chatly.verify_webhook_signature`, which is a pure function and needs
    # no client.
    class Webhooks < Base
      PATH = "/v1/webhooks/deliveries"

      # One page of delivery attempts, newest first.
      #
      # @return [Chatly::Page]
      def deliveries(query = {})
        page(PATH, query)
      end

      # @return [Enumerator]
      def auto_deliveries(query = {})
        auto(PATH, query)
      end

      # One delivery attempt, including the recorded payload and the
      # response the endpoint gave.
      def delivery(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # Re-send a recorded payload to the endpoint's CURRENT url.
      #
      # Queued, not delivered: the call returns as soon as the job is
      # enqueued, and the outcome shows up as a NEW attempt in
      # {#deliveries} rather than changing this one.
      def redeliver(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/redeliver", id), merge_body(attributes, kwargs))
      end
    end
  end
end
