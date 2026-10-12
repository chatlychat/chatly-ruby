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
    end
  end
end
