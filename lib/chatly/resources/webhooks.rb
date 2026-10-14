# frozen_string_literal: true

module Chatly
  module Resources
    # Webhook endpoints and their delivery history.
    #
    # `client.webhooks`
    #
    # Two things live here. The REGISTRY -- {#list}, {#create}, {#delete},
    # {#set_schema_version}, plus the {#events} and {#schema_versions}
    # catalogues -- and the DELIVERY LOG: {#deliveries}, {#delivery},
    # {#redeliver}.
    #
    # This class used to say endpoint registration was not key-accessible and
    # offer only the log. That was wrong, and the shape of the mistake is
    # worth remembering: `list` pointed at `GET /v1/webhooks/deliveries`,
    # so there was no method at all for `GET /v1/webhooks` and nothing
    # obviously missing to notice.
    #
    # For verifying an inbound delivery see `Chatly.verify_webhook_signature`,
    # which is a pure function and needs no client.
    class Webhooks < Base
      PATH = "/v1/webhooks"
      DELIVERIES_PATH = "/v1/webhooks/deliveries"

      # The webhook ENDPOINTS, as a bare Array of six named columns.
      #
      # `secret` is structurally absent here, and that is the whole story of
      # the secret on this surface: it is returned exactly once, by {#create},
      # and no route ever reads it back. There is no reveal route and no
      # rotation route -- losing it means deleting the endpoint and
      # registering another.
      def list(query = {})
        http_get(PATH, query)
      end

      # Register an endpoint. Answers 201.
      #
      #   client.webhooks.create(url: "https://example.com/hooks/chatly",
      #                          eventTypes: ["conversation.created", "message.created"])
      #
      # **The field is `eventTypes`, not `events`**, it is required with at
      # least one entry, and it is validated against a closed allow-list -- an
      # unknown name is a 400. {#events} is that list. Three old spellings are
      # refused on purpose rather than mapped, because silently accepting
      # `ticket.transitioned` would subscribe you to nothing.
      #
      # **This is the ONLY response in the whole API that carries `secret`.**
      # Capture it on the spot; you do not supply it, the server mints it.
      #
      # `schemaVersion:` is optional and is REFUSED here if unrecognised --
      # loud on the write, deliberately asymmetric with the dispatch path,
      # which resolves an unknown version to the latest. Omitting it lets the
      # column default decide rather than the handler.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # The subscribable event catalogue -- `{"eventTypes" => [...]}`.
      #
      # An object wrapping a flat array of NAMES: no descriptions, no
      # grouping, nothing per-workspace. It exists because the dashboard once
      # offered three events the platform never emitted; the list is now
      # checked against the emittable set at compile time, so a name here has
      # a publisher behind it.
      #
      # Which also means names you may have read in a spec are deliberately
      # ABSENT until something publishes them. Validate against this rather
      # than against your notes.
      def events(query = {})
        http_get("#{PATH}/events", query)
      end

      # `{"latest", "versions"}`, oldest first, each version carrying
      # `version`, `isLatest`, `isDeprecated` and the `eventTypes` it covers.
      #
      # `isDeprecated` is ADVISORY and non-blocking -- nothing refuses a
      # deprecated pin -- so treat it as a warning and never as an error.
      def schema_versions(query = {})
        http_get("#{PATH}/schema-versions", query)
      end

      # Pin one endpoint to a schema version.
      #
      #   client.webhooks.set_schema_version(endpoint_id, "2026-10-14")
      #
      # The body field is **`schemaVersion`** and the schema is strict, so
      # `{version: ...}` is a 400 rather than a silent no-op -- which is
      # lucky, because {#schema_versions} calls the same thing
      # `versions[].version`. The two spellings are not interchangeable.
      #
      # The response is NOT the endpoint row: it is
      # `{"id", "url", "eventTypes", "schemaVersion", "missingEventTypes"}`,
      # where `missingEventTypes` is the event NAMES this pin still does not
      # receive -- names, not a count.
      #
      # Moving the pin BACKWARD is legal and stops deliveries of the newer
      # types. Either direction takes effect on the next event, because the
      # dispatcher re-reads the column per delivery rather than caching it.
      def set_schema_version(id, schema_version = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { schemaVersion: schema_version }.merge(body) unless schema_version.nil?
        http_patch(expand("#{PATH}/{id}/schema-version", id), body)
      end

      # Remove a subscription. **200 with `{"ok" => true}`, not a 204.**
      #
      # A HARD delete, and unlike most deletes on this surface it really does
      # 404 on a miss -- the row is returned by the DELETE and its absence is
      # checked, where `ai.delete_tool` and `bot_routes.delete` report success
      # for an id that was never there.
      #
      # It was opened to keys on 2026-10-14 for the reason {#create} already
      # made: a key that can ADD a delivery target and not remove one can only
      # ever add. A deploy pipeline registering an endpoint per environment
      # leaked one into the customer's workspace on every run with nothing able
      # to clean up, and the workaround people were told to use -- repoint the
      # endpoint at a dead URL -- leaves the subscription alive and the
      # delivery log filling with failures.
      #
      # Both routes need `integrations:write`, which is the whole safety
      # argument: a credential that can add a delivery target can already do
      # the thing with consequences.
      #
      # The delivery history is NOT deleted with the endpoint -- the rows
      # reference it by id, so what you lose is the subscription, not the
      # record of what it received.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end

      # One page of delivery attempts, newest first.
      #
      # Built by the shared paginator, so the envelope carries `hasMore`
      # beside `items` and `nextCursor`.
      #
      # @return [Chatly::Page]
      def deliveries(query = {})
        page(DELIVERIES_PATH, query)
      end

      # @return [Enumerator]
      def auto_deliveries(query = {})
        auto(DELIVERIES_PATH, query)
      end

      # One delivery attempt, including the recorded payload and the
      # response the endpoint gave.
      def delivery(id)
        http_get(expand("#{DELIVERIES_PATH}/{id}", id))
      end

      # Re-send a recorded payload to the endpoint's CURRENT url.
      #
      # Queued, not delivered: the call returns as soon as the job is
      # enqueued, and the outcome shows up as a NEW attempt in
      # {#deliveries} rather than changing this one. The receiver sees the
      # same payload with a fresh signature.
      def redeliver(id, attributes = {}, **kwargs)
        http_post(expand("#{DELIVERIES_PATH}/{id}/redeliver", id), merge_body(attributes, kwargs))
      end
    end
  end
end
