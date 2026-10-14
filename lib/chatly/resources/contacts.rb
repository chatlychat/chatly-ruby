# frozen_string_literal: true

module Chatly
  module Resources
    # Contacts -- the people your agents talk to.
    #
    # `client.contacts`
    class Contacts < Base
      PATH = "/v1/contacts"

      # Largest batch `bulk_upsert` will send in one request, matching the
      # API's own cap. Over it the API answers 422, so it is worth knowing
      # before you build the array.
      BULK_MAX = 5000

      # One page of contacts.
      #
      # @param query [Hash] `cursor:`, `limit:`, `filter:` (String or Array),
      #   `sort:`, `fields:`, and `blocked:` -- `blocked: true` narrows to
      #   blocked contacts, `false` excludes them, and omitting it returns
      #   everything INCLUDING blocked people (a block is a flag, not a
      #   deletion).
      # @return [Chatly::Page]
      def list(query = {})
        page(PATH, query)
      end

      # Every contact, across pages, as a lazy Enumerator.
      #
      #   client.contacts.auto_list(limit: 200).each { |c| puts c["email"] }
      #
      # @return [Enumerator]
      def auto_list(query = {})
        auto(PATH, query)
      end

      # @param id [String] contact id
      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # Create or update one contact.
      #
      # Upsert, not create: the API matches an existing contact before
      # inserting, so calling this on every login updates rather than
      # duplicating.
      #
      #   client.contacts.upsert(externalId: "user_42", email: "ada@example.com",
      #                          name: "Ada", attributes: { "plan" => "pro" })
      #
      # Accepted fields: `externalId`, `email`, `phone`, `name`, `avatarUrl`,
      # `locale`, `timezone`, `attributes` (a free-form Hash). All optional.
      #
      # Keys go on the wire exactly as you write them -- see "Shapes" in the
      # README. `external_id:` is not `externalId:`, and the API's validator
      # silently drops a field it does not recognise, so the write would
      # succeed having ignored the thing you cared about.
      def upsert(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Upsert up to {BULK_MAX} contacts in one request.
      #
      # @param contacts [Array<Hash>, Hash] an Array is wrapped as the
      #   `{"contacts" => [...]}` body the API expects; pass a Hash to send a
      #   body of your own shape
      def bulk_upsert(contacts)
        body = contacts.is_a?(Array) ? { contacts: contacts } : contacts
        http_post("#{PATH}/bulk", body)
      end

      # Merge `merged_id` into `id`: the contact in the PATH survives, the
      # one in the body is absorbed and retired.
      #
      # Not reversible. `merged_id` must be a UUID v7 -- the API validates it
      # as one and answers 422 for anything else.
      #
      #   client.contacts.merge(survivor_id, duplicate_id)
      def merge(id, merged_id = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { mergedId: merged_id }.merge(body) unless merged_id.nil?
        http_post(expand("#{PATH}/{id}/merge", id), body)
      end

      # Add ONE tag.
      #
      # The method is plural because `surface.json` names it `add_tags` and
      # every language binding has to match that list, but the route takes a
      # single `{"tag": "..."}` body -- so this sends one tag per call. An
      # Array is an ArgumentError rather than a request the API would reject
      # (or worse, accept while dropping the field).
      #
      #   %w[vip churn-risk].each { |t| client.contacts.add_tags(id, t) }
      #
      # @param tag [String, Hash] the tag, or a body Hash of your own
      def add_tags(id, tag)
        body =
          case tag
          when Hash then tag
          when Array
            raise ArgumentError,
                  "contacts.add_tags takes one tag per call; call it once per tag"
          else { tag: tag }
          end
        http_post(expand("#{PATH}/{id}/tags", id), body)
      end

      # Remove one tag.
      #
      # The tag travels in the path and is percent-encoded for you, so a tag
      # with a space, a slash or a `%` in it addresses the right resource.
      def remove_tag(id, tag)
        http_delete(expand("#{PATH}/{id}/tags/{tag}", id, tag))
      end

      # Set the contact's marketing subscription state.
      #
      # Defaults to unsubscribing, which is what the name says. The route's
      # body is `{"unsubscribed": <boolean>}`, so it is also how you
      # RE-subscribe someone:
      #
      #   client.contacts.unsubscribe(id)                       # opt out
      #   client.contacts.unsubscribe(id, reason: "complaint")  # opt out, logged
      #   client.contacts.unsubscribe(id, unsubscribed: false)  # opt back in
      def unsubscribe(id, attributes = {}, **kwargs)
        body = { unsubscribed: true }.merge(merge_body(attributes, kwargs))
        http_post(expand("#{PATH}/{id}/unsubscribe", id), body)
      end

      # The contact's timeline -- events, conversations, authored messages and
      # survey responses merged into one stream, newest first.
      #
      # Cursor-paginated. `days:` sets the window (1-365, default 90) and
      # `limit:` the page size (1-100, default 25).
      #
      # **The cursor is an ISO-8601 instant, not an opaque token** --
      # `journeyQuerySchema` declares it as
      # `z.string().datetime({ offset: true })`, so the API rejects anything
      # that is not one with a 422. It is still a cursor: pass back the
      # `nextCursor` you were given and never construct one. A hand-built
      # timestamp looks valid, is accepted, and silently slices the timeline
      # at a boundary that does not line up with any page -- which loses or
      # repeats rows rather than failing.
      #
      # @return [Chatly::Page]
      def journey(id, query = {})
        page(expand("#{PATH}/{id}/journey", id), query)
      end

      # The whole timeline, across pages, as a lazy Enumerator.
      #
      #   client.contacts.auto_journey(id, days: 365).each { |row| puts row["kind"] }
      #
      # @return [Enumerator]
      def auto_journey(id, query = {})
        auto(expand("#{PATH}/{id}/journey", id), query)
      end

      # The operator's live customer cards for this contact --
      # `{"cards" => [{"key", "title", "state", "blocks", "text"}]}`. Answers
      # 201.
      #
      # **A POST that is a READ, and it reads YOUR backend, not ours.** It
      # fans out signed HTTPS requests to each configured card's url (grouped
      # by url and headers), waits, and returns what came back. It is not a
      # create -- the create is `client.customer_cards.create`. POST rather
      # than GET because the input is per contact and per conversation, is
      # cacheable by nobody, and a `conversationId` in a query string would
      # land in access logs beside the contact's email.
      #
      # The body is `.strict()` with one optional field, `conversationId:`,
      # so `{}` always goes up (an absent body is a 400) and any other key is
      # a 400 rather than a silent strip.
      #
      # Four things about the answer:
      #
      #   * the collection key is **`cards`**, not `items`;
      #   * the array is always as long as the number of CONFIGURED cards, in
      #     configuration order and never completion order -- a card that
      #     produced nothing comes back as `state: "error"` with
      #     `blocks: nil` rather than being left out, so read `state` for the
      #     reason and treat `blocks: nil` as a real value meaning "no data
      #     for this contact";
      #   * results are cached per card for its own `ttlSeconds`, so two
      #     calls in a row may not re-hit your backend;
      #   * an unknown or deleted contact answers `{"cards" => []}`, NOT a
      #     404 -- that is a race with a deletion rather than an
      #     authorisation failure, so this is not a way to probe whether a
      #     contact exists.
      #
      # The `Idempotency-Key` header is explicitly IGNORED on this route: no
      # replay, no 428. Validate the contact id yourself -- with cards
      # configured, a malformed id reaches Postgres and comes back as a 500,
      # while with none configured the same id answers `{"cards" => []}`
      # because the route short-circuits before the contact is looked up.
      def cards(contact_id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{contact_id}/cards", contact_id),
                  merge_body(attributes, kwargs))
      end

      # Weekly sentiment buckets for one contact --
      # `{"contactId", "days", "sampleCount", "buckets"}`.
      #
      # The window is `days:` and its FLOOR is 7, which is the trap: the
      # sibling {#journey} route takes `days: 1` happily, and here that is a
      # 400. Maximum 365, default 90, and out-of-range is REJECTED rather
      # than clamped.
      #
      # `buckets: []` beside a non-zero `sampleCount` is the normal "not
      # enough signal" answer -- the API wants a handful of scored messages
      # in the window before it will draw a line. Buckets are snapped to UTC
      # Monday, oldest first, and a week with no data is ABSENT rather than
      # zero-filled, so do not index the array by week number.
      #
      # It reads a sentiment cache and computes nothing on demand, so a
      # contact whose messages were never scored reads as no signal rather
      # than as neutral. A contact that does not exist is a 404 here -- note
      # {#cards}, on the same resource, answers an empty list instead.
      def mood(id, query = {})
        http_get(expand("#{PATH}/{id}/mood", id), query)
      end
    end
  end
end
