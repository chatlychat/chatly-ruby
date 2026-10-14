# frozen_string_literal: true

# THE DECLARED COLUMN: what this SDK expects back from each of the 162 routes,
# and the arguments needed to call them.
#
# Split out of `test/surface_lock_test.rb` when the surface went from 55
# routes to 159 and that file reached the 650-line ceiling the contract sets.
# Nothing else moved: these tables are still hand-written, still read off the
# handlers, and still the thing `surface_lock_test.rb` feeds to a fake
# transport and writes into `surface.lock.json`.
#
# It is a plain module rather than a second `*_test.rb` on purpose --
# `test/all.rb` requires every `*_test.rb` it finds and asserts the list is
# complete, so a file of tables named like a test would have to be a test.
module SurfaceLockTable
  # The response shape THIS SDK's decoder expects from each route.
  #
  # ===== READ THIS BEFORE CHANGING A VALUE ==================================
  #
  # Hand-written, from the handlers. Deliberately NOT read from
  # `surface.json`, even though the suite beside it loads that manifest for
  # the path templates and the verb: a fixture derived from the manifest
  # agrees with
  # whatever the manifest says, including when it is wrong, and that is not
  # hypothetical. `macros.list` carried `paged: true` for a day against a
  # handler that is `@PaginationExempt` and answers with a bare array. Two
  # sibling SDKs built paginators over it and shipped a decode error to real
  # customers with green suites, because their fake transports answered
  # EVERY route with `{ items, nextCursor }`.
  #
  # So this column is a second opinion. `surface_lock_test.rb` feeds each
  # method the shape declared HERE, asserts the value handed back really has that shape,
  # and writes the declaration into `surface.lock.json`;
  # `scripts/check-sdk-surface-parity.mjs` then diffs eight such columns --
  # one per backend SDK, each written independently -- against the manifest.
  # A wrong manifest row needs eight authors to misread the same handler.
  #
  # Rows that look wrong and are not:
  #
  #   * `webhooks.delete` is the one delete here that both answers a body AND
  #     404s on a miss: the row comes back from the DELETE and its absence is
  #     checked, where `ai.delete_tool` and `bot_routes.delete` report
  #     `{deleted: true}` for an id that never existed.
  #   * `root.me` is a `z.discriminatedUnion` on `principal`, which is an
  #     object at the top level whichever arm answers.
  #   * `workspace.mine` is an `array` that holds exactly one entry for a key
  #     -- the route is the cross-workspace list, and a key belongs to one
  #     workspace. One entry is not an object.
  #   * `contacts.remove_tag` is a DELETE answering 200 with the surviving
  #     contact, and `conversations.cancel_scheduled` a DELETE answering 200
  #     with the row it just cancelled (`@ZodResponse scheduledMessageSchema`).
  #     `macros.delete` is still the ONLY real 204 here -- the eight other
  #     deletes added in 2026-10 all answer 200 with a body, and they do not
  #     even agree on which: `{deleted: true}` (`ai.delete_tool`,
  #     `bot_routes.delete`), `{ok: true}` (`customer_cards.delete`,
  #     `customer_card_endpoints.delete`, `triggers.delete`), `{id}`
  #     (`brands.delete`), `{kept}` (`docs_sources.delete`) and
  #     `{restored}` (`email_templates.delete`).
  #   * `ai.tone` AND `ai.set_tone` are `array`: the PUT re-reads the rule set
  #     and answers with the same bare array the GET does, not `{rules}`.
  #   * `docs_sources.discover` is an `array` from a POST.
  #   * four reports are bare arrays (`agents`, `conversations_by_day`,
  #     `attribution`, `sources`) and the other nine are objects.
  #   * `billing.invoices`, `billing.usage_monthly`, `macros.templates`,
  #     `tickets.status_history`, `tickets.time`, `conversations.linked`,
  #     `conversations.outcomes` and `workspace.secrets` all carry a
  #     collection and are `object`, not `page`. Six spell it `items` with no
  #     `nextCursor`; `billing.invoices` is cursor-paginated and spells the
  #     envelope `data`, which is why it gets no walker in this gem rather
  #     than a `Page` that would read nil items forever.
  EXPECTED_SHAPE = {
    "ai.add_provider" => "object",
    "ai.create_tool" => "object",
    "ai.delete_tool" => "object",
    "ai.generate_tone" => "object",
    "ai.providers" => "object",
    "ai.quota" => "object",
    "ai.set_tone" => "array",
    "ai.test_provider" => "object",
    "ai.tone" => "array",
    "ai.tone_preview" => "object",
    "ai.tools" => "array",
    "ai.update_tool" => "object",

    "billing.invoices" => "object",
    "billing.plans" => "array",
    "billing.summary" => "object",
    "billing.usage" => "object",
    "billing.usage_daily" => "object",
    "billing.usage_monthly" => "object",

    "bot_routes.create" => "object",
    "bot_routes.delete" => "object",
    "bot_routes.fields" => "object",
    "bot_routes.list" => "array",
    "bot_routes.resolve" => "object",
    "bot_routes.update" => "object",

    "bots.analytics" => "object",
    "bots.create" => "object",
    "bots.deliveries" => "page",
    "bots.delivery" => "object",
    "bots.get" => "object",
    "bots.list" => "page",
    "bots.redeliver" => "object",
    "bots.rotate_external_secret" => "object",
    "bots.test_delivery" => "object",
    "bots.update" => "object",
    "bots.update_external" => "object",

    "brands.create" => "object",
    "brands.delete" => "object",
    "brands.list" => "array",
    "brands.update" => "object",

    "canvas_steps.get" => "object",
    "canvas_steps.resolve" => "object",

    "channels.adapters" => "array",
    "channels.create" => "object",
    "channels.get" => "object",
    "channels.list" => "array",
    "channels.rotate_secret" => "object",
    "channels.update" => "object",

    "contacts.add_tags" => "object",
    "contacts.bulk_upsert" => "object",
    "contacts.cards" => "object",
    "contacts.get" => "object",
    "contacts.journey" => "page",
    "contacts.list" => "page",
    "contacts.merge" => "object",
    "contacts.mood" => "object",
    "contacts.remove_tag" => "object",
    "contacts.unsubscribe" => "object",
    "contacts.upsert" => "object",

    "conversations.agent_handling" => "object",
    "conversations.cancel_scheduled" => "object",
    "conversations.generate_reply" => "object",
    "conversations.generated_replies" => "array",
    "conversations.get" => "object",
    "conversations.linked" => "object",
    "conversations.list" => "page",
    "conversations.messages" => "page",
    "conversations.outcomes" => "object",
    "conversations.record_outcome" => "object",
    "conversations.return_to_bot" => "object",
    "conversations.schedule_message" => "object",
    "conversations.scheduled_messages" => "array",
    "conversations.send" => "object",
    "conversations.set_agent_handling" => "object",
    "conversations.unattended" => "page",
    "conversations.unread_counts" => "object",
    "conversations.update_blocks" => "object",

    "customer_card_endpoints.activate_secret" => "object",
    "customer_card_endpoints.create" => "object",
    "customer_card_endpoints.delete" => "object",
    "customer_card_endpoints.list" => "array",
    "customer_card_endpoints.rotate_secret" => "object",

    "customer_cards.create" => "object",
    "customer_cards.delete" => "object",
    "customer_cards.list" => "array",
    "customer_cards.rotate_secret" => "object",
    "customer_cards.update" => "object",

    "docs_sources.create" => "object",
    "docs_sources.delete" => "object",
    "docs_sources.discover" => "array",
    "docs_sources.list" => "array",
    "docs_sources.providers" => "array",
    "docs_sources.sync" => "object",
    "docs_sources.update" => "object",
    "docs_sources.webhook" => "object",

    "email_templates.delete" => "object",
    "email_templates.list" => "array",
    "email_templates.preview" => "object",
    "email_templates.update" => "object",

    "events.list" => "page",
    "events.track" => "object",

    "kb.article" => "object",
    "kb.articles" => "page",
    "kb.collections" => "array",

    "knowledge_gaps.draft" => "object",
    "knowledge_gaps.list" => "array",
    "knowledge_gaps.update" => "object",

    "macros.actions" => "object",
    "macros.create" => "object",
    "macros.delete" => "empty",
    "macros.get" => "object",
    "macros.list" => "array",
    "macros.template" => "object",
    "macros.templates" => "object",
    "macros.update" => "object",

    "reports.agents" => "array",
    "reports.attribution" => "array",
    "reports.cohorts" => "object",
    "reports.conversations_by_day" => "array",
    "reports.labels" => "object",
    "reports.overview" => "object",
    "reports.response_times" => "object",
    "reports.sla" => "object",
    "reports.sources" => "array",
    "reports.teams" => "object",
    "reports.theme_conversations" => "object",
    "reports.themes" => "object",
    "reports.voice" => "object",

    "root.me" => "object",
    "root.whoami" => "object",

    "search.query" => "page",

    "tickets.bulk" => "object",
    "tickets.comments" => "array",
    "tickets.conversations" => "array",
    "tickets.for_conversation" => "array",
    "tickets.lineage" => "object",
    "tickets.list" => "page",
    "tickets.merge" => "object",
    "tickets.open_count" => "object",
    "tickets.queues" => "array",
    "tickets.split" => "object",
    "tickets.status_history" => "object",
    "tickets.time" => "object",

    "triggers.create" => "object",
    "triggers.delete" => "object",
    "triggers.list" => "page",

    "webhooks.create" => "object",
    "webhooks.delete" => "object",
    "webhooks.deliveries" => "page",
    "webhooks.delivery" => "object",
    "webhooks.events" => "object",
    "webhooks.list" => "array",
    "webhooks.redeliver" => "object",
    "webhooks.schema_versions" => "object",
    "webhooks.set_schema_version" => "object",

    "workspace.agent_skills" => "object",
    "workspace.inboxes" => "array",
    "workspace.key_scopes" => "array",
    "workspace.labels" => "array",
    "workspace.mine" => "array",
    "workspace.secrets" => "object",
    "workspace.settings" => "object",
    "workspace.team_members" => "array"
  }.freeze

  # The distribution of the column above: 55 routes read on 2026-10-12 and
  # the other 104 on 2026-10-14, each off its handler's `@ZodResponse` schema
  # (or, where it has none, the service return type it forwards). Asserted
  # below, because a column that said "object" 159 times would satisfy every
  # other assertion in this file and be worth nothing.
  SHAPE_COUNTS = { "array" => 33, "page" => 13, "object" => 115, "empty" => 1 }.freeze

  # Positional arguments a method needs BEYOND its path parameters, keyed by
  # the manifest's [ns, name]. A body, or a value the method accepts
  # positionally and puts in the body.
  #
  # Path parameters are not listed here -- they are generated from the
  # manifest's own template, which is what makes the normalisation below
  # honest rather than a restatement of the table.
  EXTRA_ARGS = {
    %w[ai add_provider] => [{ provider: "openai", apiKey: "sk-test-key" }],
    %w[ai create_tool] => [
      { name: "order_status", description: "Order lookup", urlTemplate: "https://x.test/o" }
    ],
    %w[ai generate_tone] => ["Write warmly. Never blame the customer."],
    %w[ai set_tone] => [[{ category: "warmth", rule: "Be warm" }]],
    %w[ai update_tool] => [{ description: "Look up one order" }],
    %w[billing usage] => ["conversation.opened"],
    %w[billing usage_daily] => ["message.sent.agent"],
    %w[bot_routes create] => [
      { botId: "00000000-0000-7000-8000-000000000006", name: "Pricing page" }
    ],
    %w[bot_routes resolve] => [{ page: { path: "/pricing" } }],
    %w[bot_routes update] => [{ name: "renamed" }],
    %w[bots create] => [{ name: "Support", systemPrompt: "You answer billing questions." }],
    %w[bots update] => [{ name: "Support (EU)" }],
    %w[bots update_external] => [{ timeoutSeconds: 20 }],
    %w[brands create] => [{ name: "Acme Support", slug: "acme" }],
    %w[brands update] => [{ primaryColor: "#2b6cb0" }],
    %w[canvas_steps resolve] => [{ canvas: { v: 1, canvasId: "receipt", blocks: [] } }],
    %w[channels create] => [{ type: "web", name: "Site", publicId: "acme-web" }],
    %w[channels update] => [{ name: "renamed" }],
    %w[contacts add_tags] => ["vip"],
    %w[contacts bulk_upsert] => [[{ email: "a@example.com" }]],
    %w[contacts cards] => [{}],
    %w[contacts merge] => ["00000000-0000-7000-8000-000000000001"],
    %w[contacts unsubscribe] => [{}],
    %w[contacts upsert] => [{ email: "a@example.com" }],
    %w[conversations generate_reply] => [{}],
    %w[conversations record_outcome] => [{ outcome: "resolved" }],
    %w[conversations return_to_bot] => ["00000000-0000-7000-8000-000000000005"],
    %w[conversations schedule_message] => [{ body: "later", sendAt: "2026-10-14T00:00:00Z" }],
    %w[conversations send] => [{ body: "hello" }],
    %w[conversations set_agent_handling] => [{ state: "handled" }],
    %w[conversations update_blocks] => [{ patches: [{ id: "status", set: { text: "Shipped" } }] }],
    %w[customer_card_endpoints create] => ["https://x.test/cards"],
    %w[customer_cards create] => [
      { key: "orders", title: "Orders", url: "https://x.test/cards", ttlSeconds: 300 }
    ],
    %w[customer_cards update] => [{ position: 2 }],
    %w[docs_sources create] => [
      { provider: "gitbook", token: "t", organizationId: "org_1", spaceId: "space_1" }
    ],
    %w[docs_sources discover] => [{ provider: "website", token: "" }],
    %w[docs_sources sync] => [{ full: true }],
    %w[docs_sources update] => [{ status: "paused" }],
    %w[email_templates preview] => [
      { kind: "workspace_invite", subject: "Join us", body: "Hello" }
    ],
    %w[email_templates update] => [{ subject: "Join us", body: "Hello {{inviteeName}}" }],
    %w[events track] => [{ contactId: "00000000-0000-7000-8000-000000000004", name: "evt" }],
    %w[knowledge_gaps update] => ["dismissed"],
    %w[macros create] => [{ name: "n", scope: "workspace", body: "b" }],
    %w[macros update] => [{ name: "renamed" }],
    %w[search query] => ["a search term"],
    %w[tickets bulk] => [{ ids: ["00000000-0000-7000-8000-000000000003"], action: "status" }],
    %w[tickets merge] => ["00000000-0000-7000-8000-000000000002"],
    %w[tickets split] => [{ title: "the other half" }],
    %w[triggers create] => [
      { name: "Greet", eventType: "conversation.created", enabled: true,
      conditions: [], actions: [{ type: "send_message", params: {} }] }
    ],
    %w[webhooks create] => [{ url: "https://x.test/hooks", eventTypes: ["conversation.created"] }],
    %w[webhooks redeliver] => [{}],
    %w[webhooks set_schema_version] => ["2026-10-14"]
  }.freeze
end
