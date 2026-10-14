# frozen_string_literal: true

module Chatly
  module Resources
    # Bot routes -- which bot answers which visitor.
    #
    # `client.bot_routes`
    #
    # A route is a priority, a bot and a set of conditions. The worker
    # evaluates them in order on an inbound message and the first match wins,
    # so ORDER IS THE SEMANTICS here: {#list} returns them in evaluation
    # order, and {#resolve} is how you check what that order actually does
    # before a visitor finds out.
    class BotRoutes < Base
      PATH = "/v1/bot-routes"

      # The condition operators. `field` is a closed vocabulary too -- read
      # {#fields} rather than guessing one, because an unknown field is a
      # 400.
      OPERATORS = %w[eq neq in gt lt contains matches].freeze

      # Every bot route, in EVALUATION ORDER (priority ascending, then
      # creation time). A bare Array.
      #
      # The handler reads no query parameters at all -- it is
      # `@PaginationExempt` and has no `@Query` -- so `cursor:`, `limit:`,
      # `sort:` and `filter:` are not merely ignored by a schema, they are
      # never looked at.
      #
      # It includes DISABLED routes, which {#resolve} does not: a route
      # missing from a resolve answer is often simply switched off, and this
      # is where you find that out.
      def list(query = {})
        http_get(PATH, query)
      end

      # The routing-condition vocabulary --
      # `{"fields", "prefixes", "operators", "evaluate"}`. An OBJECT, not the
      # bare array the name suggests. Static: no workspace, no database.
      #
      # Read it before writing a condition, because the field list is CLOSED
      # (six fixed keys plus three open prefixes) and an unknown name is a
      # 400.
      #
      # The `prefixes` half is the security-relevant part.
      # `context.verified.*` is covered by your signature;
      # `context.unverified.*` and `contact.attributes.*` are
      # VISITOR-WRITABLE. Never key a route that grants access on one of the
      # last two.
      def fields(query = {})
        http_get("#{PATH}/fields", query)
      end

      # Create a route. Answers 201.
      #
      #   client.bot_routes.create(botId: bot_id, name: "Pricing page",
      #                            conditions: [{ field: "page.path", op: "contains",
      #                                           value: "/pricing" }])
      #
      # `botId:` and `name:` are required; `priority:` (0-10,000), `enabled:`,
      # `channelTypes:`, `conditions:` (max 20), `brandId:` and `evaluate:`
      # (`"conversation_start"` or `"every_message"`) are optional and
      # defaulted by the COLUMN rather than the schema -- so the response is
      # where you learn what they became.
      #
      # This is the only route in the namespace that checks `botId` belongs
      # to your workspace; {#update} does not.
      #
      # Two ways to create a route that never fires, neither of them an
      # error: a condition's `value` is optional in the schema, so
      # `{field: "body", op: "contains"}` with no value is accepted and
      # matches nothing; and `channelTypes` is a list of free strings with no
      # enum, so a typo is a route that silently never applies.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Update a route. Every create field, optional -- and unlike
      # `bots.update`, an empty body is accepted and simply bumps the
      # timestamp.
      #
      # It does NOT verify that a new `botId` is one of yours. Isolation here
      # rests on row-level security rather than a predicate in the query, so
      # a wrong-workspace id surfaces as a 404 rather than a validation
      # error.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Dry-run the routing table against a hypothetical visitor.
      #
      #   client.bot_routes.resolve(page: { path: "/pricing" },
      #                             contact: { identityVerified: true })
      #
      # A READ dressed as a POST -- the input is a page, a context, a contact
      # and a moment, which is too much structure for a query string -- and
      # it writes nothing: no conversation is read, no contact, no stored
      # visitor context. It answers **201** anyway, because Nest's POST
      # default applies and there is no `@HttpCode`.
      #
      # Answers `{"selected", "routes", "event"}`. `selected` is the route
      # that would answer, or nil. `routes` is every ENABLED route in
      # evaluation order with its verdict (`matched`,
      # `not_eligible_at_moment`, `channel_excluded`, `brand_excluded`,
      # `condition_failed`) -- disabled routes are dropped entirely rather
      # than reported, so check {#list} if one you expected is absent. `event`
      # is the object the conditions were evaluated against, which is where
      # you find out that a field path resolved to nothing.
      #
      # A failed condition reports `actual`, the value the field resolved to.
      # Absent means the visitor has no such attribute; a real value means
      # routing works and your expectation was wrong. Different bugs,
      # identical symptom.
      #
      # `moment:` defaults to `"conversation_start"` and is what to reach for
      # when a route "works on the first message and then stops": at
      # `"follow_up"` only routes that opted into `every_message` are
      # eligible at all.
      #
      # This is the production decision and not an approximation of it -- the
      # function the worker calls per inbound message is a wrapper over the
      # one that answers here. What it does NOT apply is the answerability
      # guards (thread open, human in control, bot already replying), so
      # `selected` can name a route that would not actually speak.
      #
      # The body is `.strict()`, which on this API is unusual and welcome: a
      # misspelled key here is a 400 instead of a silent drop. `{}` is a
      # valid call -- every field has a default.
      def resolve(attributes = {}, **kwargs)
        http_post("#{PATH}/resolve", merge_body(attributes, kwargs))
      end

      # Delete a route.
      #
      # **200 with `{"deleted" => true}`, not a 204** -- and `deleted` is a
      # literal, because the service never checks the row count. An unknown
      # id and an already-deleted one both report success, so this is not a
      # way to find out whether a route existed. Note the sibling
      # `brands.delete` answers `{"id" => ...}` instead: the deletes on this
      # surface confirm themselves in three different ways.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
