# frozen_string_literal: true

require_relative "test_helper"

# Every method in `packages/sdk-spec/surface.json`, called, with the verb and
# path it put on the wire asserted.
#
# The table below is the authoritative copy and always runs. The last test
# cross-checks it against `surface.json` itself when the spec file is
# reachable, which it is inside the monorepo and is not inside an installed
# gem -- that one test skips rather than failing, and a skip is visible in
# the suite's output.
#
# Calling each method is the point. A test that only asked
# `respond_to?(:cancel_scheduled)` would have passed while the method built
# the wrong URL, and a wrong URL is a 404 in someone else's production.
class SurfaceTest < ChatlyTest
  # ns, ruby method, args, verb, path
  SURFACE = [
    [:ai, :add_provider, [{ provider: "openai", apiKey: "sk-test-key" }], "POST",
     "/v1/ai-providers"],
    [:ai, :create_tool,
     [{ name: "order_status", description: "Order lookup", urlTemplate: "https://x.test/o" }],
     "POST", "/v1/ai/tools"],
    [:ai, :delete_tool, ["tool_1"], "DELETE", "/v1/ai/tools/tool_1"],
    [:ai, :generate_tone, ["Write warmly. Never blame the customer."], "POST",
     "/v1/ai/tone/generate"],
    [:ai, :providers, [], "GET", "/v1/ai-providers"],
    [:ai, :quota, [], "GET", "/v1/ai/quota"],
    [:ai, :set_tone, [[{ category: "warmth", rule: "Be warm" }]], "PUT", "/v1/ai/tone"],
    [:ai, :test_provider, ["openai"], "POST", "/v1/ai-providers/openai/test"],
    [:ai, :tone, [], "GET", "/v1/ai/tone"],
    [:ai, :tone_preview, [], "GET", "/v1/ai/tone/preview"],
    [:ai, :tools, [], "GET", "/v1/ai/tools"],
    [:ai, :update_tool, ["tool_1", { description: "Look up one order" }], "PATCH",
     "/v1/ai/tools/tool_1"],

    [:billing, :invoices, [], "GET", "/v1/billing/invoices"],
    [:billing, :plans, [], "GET", "/v1/billing/plans"],
    [:billing, :summary, [], "GET", "/v1/billing"],
    [:billing, :usage, ["conversation.opened"], "GET", "/v1/billing/usage"],
    [:billing, :usage_daily, ["message.sent.agent"], "GET", "/v1/billing/usage/daily"],
    [:billing, :usage_monthly, [], "GET", "/v1/billing/usage/monthly"],

    [:bot_routes, :create,
     [{ botId: "00000000-0000-7000-8000-000000000006", name: "Pricing page" }],
     "POST", "/v1/bot-routes"],
    [:bot_routes, :delete, ["br_1"], "DELETE", "/v1/bot-routes/br_1"],
    [:bot_routes, :fields, [], "GET", "/v1/bot-routes/fields"],
    [:bot_routes, :list, [], "GET", "/v1/bot-routes"],
    [:bot_routes, :resolve, [{ page: { path: "/pricing" } }], "POST", "/v1/bot-routes/resolve"],
    [:bot_routes, :update, ["br_1", { name: "renamed" }], "PATCH", "/v1/bot-routes/br_1"],

    [:bots, :analytics, ["bot_1"], "GET", "/v1/bots/bot_1/analytics"],
    [:bots, :create, [{ name: "Support", systemPrompt: "You answer billing questions." }], "POST",
     "/v1/bots"],
    [:bots, :deliveries, ["bot_1"], "GET", "/v1/bots/bot_1/deliveries"],
    [:bots, :delivery, ["bot_1", "del_1"], "GET", "/v1/bots/bot_1/deliveries/del_1"],
    [:bots, :get, ["bot_1"], "GET", "/v1/bots/bot_1"],
    [:bots, :list, [], "GET", "/v1/bots"],
    [:bots, :redeliver, ["bot_1", "del_1"], "POST", "/v1/bots/bot_1/deliveries/del_1/redeliver"],
    [:bots, :rotate_external_secret, ["bot_1"], "POST", "/v1/bots/bot_1/external/rotate-secret"],
    [:bots, :test_delivery, ["bot_1"], "POST", "/v1/bots/bot_1/test-delivery"],
    [:bots, :update, ["bot_1", { name: "Support (EU)" }], "PATCH", "/v1/bots/bot_1"],
    [:bots, :update_external, ["bot_1", { timeoutSeconds: 20 }], "PATCH",
     "/v1/bots/bot_1/external"],

    [:brands, :create, [{ name: "Acme Support", slug: "acme" }], "POST", "/v1/brands"],
    [:brands, :delete, ["brand_1"], "DELETE", "/v1/brands/brand_1"],
    [:brands, :list, [], "GET", "/v1/brands"],
    [:brands, :update, ["brand_1", { primaryColor: "#2b6cb0" }], "PATCH", "/v1/brands/brand_1"],

    [:canvas_steps, :get, ["step_1"], "GET", "/v1/canvas-steps/step_1"],
    [:canvas_steps, :resolve,
     ["step_1", { canvas: { v: 1, canvasId: "receipt", blocks: [] } }],
     "POST", "/v1/canvas-steps/step_1/resolve"],

    [:channels, :adapters, [], "GET", "/v1/channels/adapters"],
    [:channels, :create, [{ type: "web", name: "Site", publicId: "acme-web" }], "POST",
     "/v1/channels"],
    [:channels, :get, ["ch_1"], "GET", "/v1/channels/ch_1"],
    [:channels, :list, [], "GET", "/v1/channels"],
    [:channels, :rotate_secret, ["ch_1"], "POST", "/v1/channels/ch_1/secret/rotate"],
    [:channels, :update, ["ch_1", { name: "renamed" }], "PATCH", "/v1/channels/ch_1"],

    [:contacts, :add_tags, ["c_1", "vip"], "POST", "/v1/contacts/c_1/tags"],
    [:contacts, :bulk_upsert, [[{ email: "a@example.com" }]], "POST", "/v1/contacts/bulk"],
    [:contacts, :cards, ["c_1", {}], "POST", "/v1/contacts/c_1/cards"],
    [:contacts, :get, ["c_1"], "GET", "/v1/contacts/c_1"],
    [:contacts, :journey, ["c_1"], "GET", "/v1/contacts/c_1/journey"],
    [:contacts, :list, [], "GET", "/v1/contacts"],
    [:contacts, :merge, ["c_1", "00000000-0000-7000-8000-000000000001"], "POST",
     "/v1/contacts/c_1/merge"],
    [:contacts, :mood, ["c_1"], "GET", "/v1/contacts/c_1/mood"],
    [:contacts, :remove_tag, ["c_1", "vip"], "DELETE", "/v1/contacts/c_1/tags/vip"],
    [:contacts, :unsubscribe, ["c_1", {}], "POST", "/v1/contacts/c_1/unsubscribe"],
    [:contacts, :upsert, [{ email: "a@example.com" }], "POST", "/v1/contacts"],

    [:conversations, :agent_handling, ["v_1"], "GET", "/v1/conversations/v_1/agent-handling"],
    [:conversations, :cancel_scheduled, ["s_1"], "DELETE",
     "/v1/conversations/scheduled-messages/s_1"],
    [:conversations, :generate_reply, ["v_1", {}], "POST",
     "/v1/conversations/v_1/generated-replies"],
    [:conversations, :generated_replies, ["v_1"], "GET", "/v1/conversations/v_1/generated-replies"],
    [:conversations, :get, ["v_1"], "GET", "/v1/conversations/v_1"],
    [:conversations, :linked, ["v_1"], "GET", "/v1/conversations/v_1/linked"],
    [:conversations, :list, [], "GET", "/v1/conversations"],
    [:conversations, :messages, ["v_1"], "GET", "/v1/conversations/v_1/messages"],
    [:conversations, :outcomes, ["v_1"], "GET", "/v1/conversations/v_1/outcomes"],
    [:conversations, :record_outcome, ["v_1", { outcome: "resolved" }], "POST",
     "/v1/conversations/v_1/outcomes"],
    [:conversations, :return_to_bot, ["v_1", "00000000-0000-7000-8000-000000000005"], "POST",
     "/v1/conversations/v_1/return-to-bot"],
    [:conversations, :schedule_message,
     ["v_1", { body: "later", sendAt: "2026-10-14T00:00:00Z" }],
     "POST", "/v1/conversations/v_1/scheduled-messages"],
    [:conversations, :scheduled_messages, ["v_1"], "GET",
     "/v1/conversations/v_1/scheduled-messages"],
    [:conversations, :send_message, ["v_1", { body: "hello" }], "POST",
     "/v1/conversations/v_1/messages"],
    [:conversations, :set_agent_handling, ["v_1", { state: "handled" }], "PUT",
     "/v1/conversations/v_1/agent-handling"],
    [:conversations, :unattended, [], "GET", "/v1/conversations/unattended"],
    [:conversations, :unread_counts, [], "GET", "/v1/conversations/unread-counts"],
    [:conversations, :update_blocks,
     ["v_1", "msg_1", { patches: [{ id: "status", set: { text: "Shipped" } }] }],
     "PATCH", "/v1/conversations/v_1/messages/msg_1/blocks"],

    [:customer_card_endpoints, :activate_secret, ["cce_1"], "POST",
     "/v1/customer-card-endpoints/cce_1/activate-secret"],
    [:customer_card_endpoints, :create, ["https://x.test/cards"], "POST",
     "/v1/customer-card-endpoints"],
    [:customer_card_endpoints, :delete, ["cce_1"], "DELETE", "/v1/customer-card-endpoints/cce_1"],
    [:customer_card_endpoints, :list, [], "GET", "/v1/customer-card-endpoints"],
    [:customer_card_endpoints, :rotate_secret, ["cce_1"], "POST",
     "/v1/customer-card-endpoints/cce_1/rotate-secret"],

    [:customer_cards, :create,
     [{ key: "orders", title: "Orders", url: "https://x.test/cards", ttlSeconds: 300 }],
     "POST", "/v1/customer-cards"],
    [:customer_cards, :delete, ["card_1"], "DELETE", "/v1/customer-cards/card_1"],
    [:customer_cards, :list, [], "GET", "/v1/customer-cards"],
    [:customer_cards, :rotate_secret, ["card_1"], "POST",
     "/v1/customer-cards/card_1/rotate-secret"],
    [:customer_cards, :update, ["card_1", { position: 2 }], "PATCH", "/v1/customer-cards/card_1"],

    [:docs_sources, :create,
     [{ provider: "gitbook", token: "t", organizationId: "org_1", spaceId: "space_1" }],
     "POST", "/v1/docs-sources"],
    [:docs_sources, :delete, ["src_1"], "DELETE", "/v1/docs-sources/src_1"],
    [:docs_sources, :discover, [{ provider: "website", token: "" }], "POST",
     "/v1/docs-sources/discover"],
    [:docs_sources, :list, [], "GET", "/v1/docs-sources"],
    [:docs_sources, :providers, [], "GET", "/v1/docs-sources/providers"],
    [:docs_sources, :sync, ["src_1", { full: true }], "POST", "/v1/docs-sources/src_1/sync"],
    [:docs_sources, :update, ["src_1", { status: "paused" }], "PATCH", "/v1/docs-sources/src_1"],
    [:docs_sources, :webhook, ["src_1"], "POST", "/v1/docs-sources/src_1/webhook"],

    [:email_templates, :delete, ["workspace_invite"], "DELETE",
     "/v1/email-templates/workspace_invite"],
    [:email_templates, :list, [], "GET", "/v1/email-templates"],
    [:email_templates, :preview,
     [{ kind: "workspace_invite", subject: "Join us", body: "Hello" }],
     "POST", "/v1/email-templates/preview"],
    [:email_templates, :update,
     ["workspace_invite", { subject: "Join us", body: "Hello {{inviteeName}}" }],
     "PUT", "/v1/email-templates/workspace_invite"],

    [:events, :list, [], "GET", "/v1/cdp/events"],
    [:events, :track, [{ contactId: "00000000-0000-7000-8000-000000000004", name: "evt" }], "POST",
     "/v1/cdp/events"],

    [:kb, :article, ["how-to-reset"], "GET", "/v1/kb/articles/how-to-reset"],
    [:kb, :articles, [], "GET", "/v1/kb/articles"],
    [:kb, :collections, [], "GET", "/v1/kb/collections"],

    [:knowledge_gaps, :draft, ["gap_1"], "POST", "/v1/knowledge-gaps/gap_1/draft"],
    [:knowledge_gaps, :list, [], "GET", "/v1/knowledge-gaps"],
    [:knowledge_gaps, :update, ["gap_1", "dismissed"], "PATCH", "/v1/knowledge-gaps/gap_1"],

    [:macros, :actions, [], "GET", "/v1/macros/actions"],
    [:macros, :create, [{ name: "n", scope: "workspace", body: "b" }], "POST", "/v1/macros"],
    [:macros, :delete, ["m_1"], "DELETE", "/v1/macros/m_1"],
    [:macros, :get, ["m_1"], "GET", "/v1/macros/m_1"],
    [:macros, :list, [], "GET", "/v1/macros"],
    [:macros, :template, ["refund-issued"], "GET", "/v1/macros/templates/refund-issued"],
    [:macros, :templates, [], "GET", "/v1/macros/templates"],
    [:macros, :update, ["m_1", { name: "renamed" }], "PATCH", "/v1/macros/m_1"],

    [:reports, :agents, [], "GET", "/v1/reports/agents"],
    [:reports, :attribution, [], "GET", "/v1/reports/attribution"],
    [:reports, :cohorts, [], "GET", "/v1/reports/cohorts"],
    [:reports, :conversations_by_day, [], "GET", "/v1/reports/conversations-by-day"],
    [:reports, :labels, [], "GET", "/v1/reports/labels"],
    [:reports, :overview, [], "GET", "/v1/reports/overview"],
    [:reports, :response_times, [], "GET", "/v1/reports/response-times"],
    [:reports, :sla, [], "GET", "/v1/reports/sla"],
    [:reports, :sources, [], "GET", "/v1/reports/sources"],
    [:reports, :teams, [], "GET", "/v1/reports/teams"],
    [:reports, :theme_conversations, ["theme_1"], "GET",
     "/v1/reports/themes/theme_1/conversations"],
    [:reports, :themes, [], "GET", "/v1/reports/themes"],
    [:reports, :voice, [], "GET", "/v1/reports/voice"],

    [nil, :me, [], "GET", "/v1/me"],
    [nil, :whoami, [], "GET", "/v1/api-keys/whoami"],

    [:search, :query, ["a search term"], "GET", "/v1/search"],

    [:tickets, :bulk, [{ ids: ["00000000-0000-7000-8000-000000000003"], action: "status" }], "POST",
     "/v1/tickets/bulk"],
    [:tickets, :comments, ["t_1"], "GET", "/v1/tickets/t_1/comments"],
    [:tickets, :conversations, ["t_1"], "GET", "/v1/tickets/t_1/conversations"],
    [:tickets, :for_conversation, ["v_1"], "GET", "/v1/tickets/for-conversation/v_1"],
    [:tickets, :lineage, ["t_1"], "GET", "/v1/tickets/t_1/lineage"],
    [:tickets, :list, [], "GET", "/v1/tickets"],
    [:tickets, :merge, ["t_1", "00000000-0000-7000-8000-000000000002"], "POST",
     "/v1/tickets/t_1/merge"],
    [:tickets, :open_count, ["v_1"], "GET", "/v1/tickets/open-count/v_1"],
    [:tickets, :queues, [], "GET", "/v1/tickets/queues"],
    [:tickets, :split, ["t_1", { title: "the other half" }], "POST", "/v1/tickets/t_1/split"],
    [:tickets, :status_history, ["t_1"], "GET", "/v1/tickets/t_1/status-history"],
    [:tickets, :time, ["t_1"], "GET", "/v1/tickets/t_1/time"],

    [:triggers, :create,
     [{ name: "Greet", eventType: "conversation.created", enabled: true,
        conditions: [], actions: [{ type: "send_message", params: {} }] }],
     "POST", "/v1/triggers"],
    [:triggers, :delete, ["trg_1"], "DELETE", "/v1/triggers/trg_1"],
    [:triggers, :list, [], "GET", "/v1/triggers"],

    [:visitors, :start_conversation, ["c_1"], "POST",
     "/v1/visitors/c_1/start-conversation"],

    [:webhooks, :create,
     [{ url: "https://x.test/hooks", eventTypes: ["conversation.created"] }],
     "POST", "/v1/webhooks"],
    [:webhooks, :delete, ["w_1"], "DELETE", "/v1/webhooks/w_1"],
    [:webhooks, :deliveries, [], "GET", "/v1/webhooks/deliveries"],
    [:webhooks, :delivery, ["d_1"], "GET", "/v1/webhooks/deliveries/d_1"],
    [:webhooks, :events, [], "GET", "/v1/webhooks/events"],
    [:webhooks, :list, [], "GET", "/v1/webhooks"],
    [:webhooks, :redeliver, ["d_1", {}], "POST", "/v1/webhooks/deliveries/d_1/redeliver"],
    [:webhooks, :schema_versions, [], "GET", "/v1/webhooks/schema-versions"],
    [:webhooks, :set_schema_version, ["w_1", "2026-10-14"], "PATCH",
     "/v1/webhooks/w_1/schema-version"],

    [:workspace, :agent_skills, [], "GET", "/v1/agents/skills"],
    [:workspace, :inboxes, [], "GET", "/v1/inboxes"],
    [:workspace, :key_scopes, [], "GET", "/v1/api-keys/scopes"],
    [:workspace, :labels, [], "GET", "/v1/labels"],
    [:workspace, :mine, [], "GET", "/v1/workspaces/me"],
    [:workspace, :secrets, [], "GET", "/v1/workspace/secrets"],
    [:workspace, :settings, [], "GET", "/v1/workspace/settings"],
    [:workspace, :team_members, ["team_1"], "GET", "/v1/teams/team_1/members"]
  ].freeze

  # `surface.json` name => the Ruby name, where they differ.
  #
  # `send` is the only one, and it has to differ: `Object#send` is Ruby's
  # "call a method by name" and shadowing it on a public object breaks
  # metaprogramming and serialisers.
  RENAMED = { "send" => "send_message" }.freeze

  def test_the_table_covers_the_whole_surface
    assert_equal 163, SURFACE.length, "surface.json declares 163 methods"
  end

  # Response shape per [ns, method], so the fake answers each route the way
  # the route does. `nil` means "not paged": a plain object.
  SHAPES = {
    [:ai, :set_tone] => :array,
    [:ai, :tone] => :array,
    [:ai, :tools] => :array,
    [:billing, :plans] => :array,
    [:bot_routes, :list] => :array,
    [:bots, :deliveries] => :paged,
    [:bots, :list] => :paged,
    [:brands, :list] => :array,
    [:channels, :adapters] => :array,
    [:channels, :list] => :array,
    [:contacts, :journey] => :paged,
    [:contacts, :list] => :paged,
    [:conversations, :generated_replies] => :array,
    [:conversations, :list] => :paged,
    [:conversations, :messages] => :paged,
    [:conversations, :scheduled_messages] => :array,
    [:conversations, :unattended] => :paged,
    [:customer_card_endpoints, :list] => :array,
    [:customer_cards, :list] => :array,
    [:docs_sources, :discover] => :array,
    [:docs_sources, :list] => :array,
    [:docs_sources, :providers] => :array,
    [:email_templates, :list] => :array,
    [:events, :list] => :paged,
    [:kb, :articles] => :paged,
    [:kb, :collections] => :array,
    [:knowledge_gaps, :list] => :array,
    [:macros, :list] => :array,
    [:reports, :agents] => :array,
    [:reports, :attribution] => :array,
    [:reports, :conversations_by_day] => :array,
    [:reports, :sources] => :array,
    [:search, :query] => :paged,
    [:tickets, :comments] => :array,
    [:tickets, :conversations] => :array,
    [:tickets, :for_conversation] => :array,
    [:tickets, :list] => :paged,
    [:tickets, :queues] => :array,
    [:triggers, :list] => :paged,
    [:webhooks, :deliveries] => :paged,
    [:webhooks, :list] => :array,
    [:workspace, :inboxes] => :array,
    [:workspace, :key_scopes] => :array,
    [:workspace, :labels] => :array,
    [:workspace, :mine] => :array,
    [:workspace, :team_members] => :array,
  }.freeze

  def shaped_transport(namespace, method)
    FakeTransport.new do |_r, _n|
      case SHAPES[[namespace, method]]
      when :paged then FakeTransport.page([], nil)
      when :array then FakeTransport.json(200, [])
      else FakeTransport.json(200, {})
      end
    end
  end

  def test_every_method_hits_the_right_verb_and_path
    SURFACE.each do |namespace, method, args, verb, path|
      transport = shaped_transport(namespace, method)
      client = build_client(transport: transport)
      target = namespace.nil? ? client : client.public_send(namespace)
      target.public_send(method, *args)

      label = "#{namespace || 'client'}.#{method}"
      request = transport.requests.fetch(0)

      assert_equal 1, transport.requests.length, "#{label} made more than one request"
      assert_equal verb, request.method, "#{label} used the wrong verb"
      assert_equal path, path_of(request), "#{label} built the wrong path"
    end
  end

  def test_writes_carry_an_idempotency_key_and_reads_do_not
    SURFACE.each do |namespace, method, args, verb, _path|
      transport = shaped_transport(namespace, method)
      client = build_client(transport: transport)
      target = namespace.nil? ? client : client.public_send(namespace)
      target.public_send(method, *args)

      label = "#{namespace || 'client'}.#{method}"
      key = transport.requests.fetch(0).headers["idempotency-key"]
      if Chatly::Dispatcher::WRITE_METHODS.include?(verb)
        refute_nil key, "#{label} is a write and sent no Idempotency-Key"
      else
        assert_nil key, "#{label} is a read and should not send an Idempotency-Key"
      end
    end
  end

  def test_no_namespace_shadows_a_ruby_builtin_on_object
    # `send`, `class`, `method`, `tap`, `hash`, `display`, `then`... a
    # namespace method with one of these names would be called by something
    # that never meant to call us.
    dangerous = Object.instance_methods
    SURFACE.each do |namespace, method, _args, _verb, _path|
      next if namespace.nil?

      refute_includes dangerous, method,
                      "#{namespace}.#{method} shadows Object##{method}"
    end
  end

  # The cross-check. It is the one test here that depends on a file outside
  # this package, so it skips when that file is not reachable -- and a skip
  # shows up in the suite's output rather than passing quietly.
  def test_matches_surface_json_when_the_spec_is_reachable
    # Monorepo first, then a mirror's vendored copy.
    spec_path = [
      File.expand_path("../../sdk-spec/surface.json", __dir__),
      File.expand_path("../sdk-spec/surface.json", __dir__),
    ].find { |p| File.exist?(p) } || File.expand_path("../../sdk-spec/surface.json", __dir__)
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(spec_path)

    spec = JSON.parse(File.read(spec_path))

    assert_equal "https://api.chatlychat.com", spec["baseUrl"]
    assert_equal spec["baseUrl"], Chatly::Client::DEFAULT_API_URL

    declared = spec.fetch("entries").map do |entry|
      ns = entry.fetch("ns") == "root" ? nil : entry.fetch("ns").to_sym
      name = RENAMED.fetch(entry.fetch("name"), entry.fetch("name"))
      [ns, name.to_sym, entry.fetch("http"), entry.fetch("path")]
    end
    covered = SURFACE.map { |ns, method, _args, verb, _path| [ns, method, verb] }

    missing = declared.reject { |ns, method, verb, _p| covered.include?([ns, method, verb]) }

    assert_empty missing, "surface.json declares methods this SDK does not implement"
    assert_equal declared.length, SURFACE.length

    # And the paths agree once placeholders are allowed for.
    declared.each do |ns, method, _verb, template|
      row = SURFACE.find { |n, m, _a, _v, _p| n == ns && m == method }
      pattern = Regexp.new("\\A#{Regexp.escape(template).gsub(/\\\{\w+\\\}/, '[^/]+')}\\z")

      assert_match pattern, row.fetch(4), "#{ns}.#{method} does not match #{template}"
    end
  end

  def test_the_two_helpers_in_surface_json_exist_as_module_functions
    assert_respond_to Chatly, :verify_webhook_signature
    assert_respond_to Chatly, :identity_hash
  end
end
