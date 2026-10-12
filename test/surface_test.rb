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
    [nil, :whoami, [], "GET", "/v1/api-keys/whoami"],

    [:contacts, :list, [], "GET", "/v1/contacts"],
    [:contacts, :get, ["c_1"], "GET", "/v1/contacts/c_1"],
    [:contacts, :upsert, [{ email: "a@example.com" }], "POST", "/v1/contacts"],
    [:contacts, :bulk_upsert, [[{ email: "a@example.com" }]], "POST", "/v1/contacts/bulk"],
    [:contacts, :merge, ["c_1", "c_2"], "POST", "/v1/contacts/c_1/merge"],
    [:contacts, :add_tags, ["c_1", "vip"], "POST", "/v1/contacts/c_1/tags"],
    [:contacts, :remove_tag, ["c_1", "vip"], "DELETE", "/v1/contacts/c_1/tags/vip"],
    [:contacts, :unsubscribe, ["c_1"], "POST", "/v1/contacts/c_1/unsubscribe"],
    [:contacts, :journey, ["c_1"], "GET", "/v1/contacts/c_1/journey"],

    [:conversations, :list, [], "GET", "/v1/conversations"],
    [:conversations, :get, ["v_1"], "GET", "/v1/conversations/v_1"],
    [:conversations, :messages, ["v_1"], "GET", "/v1/conversations/v_1/messages"],
    [:conversations, :send_message, ["v_1", { body: "hi" }], "POST",
     "/v1/conversations/v_1/messages"],
    [:conversations, :unattended, [], "GET", "/v1/conversations/unattended"],
    [:conversations, :agent_handling, ["v_1"], "GET", "/v1/conversations/v_1/agent-handling"],
    [:conversations, :set_agent_handling, ["v_1", { state: "handled" }], "PUT",
     "/v1/conversations/v_1/agent-handling"],
    [:conversations, :generated_replies, ["v_1"], "GET",
     "/v1/conversations/v_1/generated-replies"],
    [:conversations, :generate_reply, ["v_1", { body: "draft" }], "POST",
     "/v1/conversations/v_1/generated-replies"],
    [:conversations, :scheduled_messages, ["v_1"], "GET",
     "/v1/conversations/v_1/scheduled-messages"],
    [:conversations, :schedule_message, ["v_1", { body: "later" }], "POST",
     "/v1/conversations/v_1/scheduled-messages"],
    [:conversations, :cancel_scheduled, ["s_1"], "DELETE",
     "/v1/conversations/scheduled-messages/s_1"],

    [:tickets, :list, [], "GET", "/v1/tickets"],
    [:tickets, :comments, ["t_1"], "GET", "/v1/tickets/t_1/comments"],
    [:tickets, :for_conversation, ["v_1"], "GET", "/v1/tickets/for-conversation/v_1"],
    [:tickets, :queues, [], "GET", "/v1/tickets/queues"],
    [:tickets, :merge, ["t_1", "t_2"], "POST", "/v1/tickets/t_1/merge"],
    [:tickets, :split, ["t_1", { title: "half" }], "POST", "/v1/tickets/t_1/split"],
    [:tickets, :bulk, [{ ids: ["t_1"], action: "status" }], "POST", "/v1/tickets/bulk"],

    [:macros, :list, [], "GET", "/v1/macros"],
    [:macros, :create, [{ name: "n", scope: "workspace", body: "b" }], "POST", "/v1/macros"],
    [:macros, :update, ["m_1", { name: "n2" }], "PATCH", "/v1/macros/m_1"],
    [:macros, :delete, ["m_1"], "DELETE", "/v1/macros/m_1"],

    [:kb, :articles, [], "GET", "/v1/kb/articles"],
    [:kb, :article, ["how-to-reset"], "GET", "/v1/kb/articles/how-to-reset"],
    [:kb, :collections, [], "GET", "/v1/kb/collections"],

    [:search, :query, ["refund"], "GET", "/v1/search"],

    [:events, :track, [{ contactId: "c_1", name: "x" }], "POST", "/v1/cdp/events"],
    [:events, :list, [], "GET", "/v1/cdp/events"],

    [:webhooks, :deliveries, [], "GET", "/v1/webhooks/deliveries"],
    [:webhooks, :delivery, ["d_1"], "GET", "/v1/webhooks/deliveries/d_1"],
    [:webhooks, :redeliver, ["d_1"], "POST", "/v1/webhooks/deliveries/d_1/redeliver"],

    [:reports, :overview, [], "GET", "/v1/reports/overview"],
    [:reports, :agents, [], "GET", "/v1/reports/agents"],
    [:reports, :conversations_by_day, [], "GET", "/v1/reports/conversations-by-day"],
    [:reports, :sla, [], "GET", "/v1/reports/sla"],

    [:channels, :list, [], "GET", "/v1/channels"],
    [:channels, :get, ["ch_1"], "GET", "/v1/channels/ch_1"],

    [:billing, :plans, [], "GET", "/v1/billing/plans"],
    [:billing, :usage, [], "GET", "/v1/billing/usage"],

    [:workspace, :settings, [], "GET", "/v1/workspace/settings"],
    [:workspace, :labels, [], "GET", "/v1/labels"],
    [:workspace, :inboxes, [], "GET", "/v1/inboxes"],
    [:workspace, :team_members, ["team_1"], "GET", "/v1/teams/team_1/members"],
    [:workspace, :agent_skills, [], "GET", "/v1/agents/skills"]
  ].freeze

  # `surface.json` name => the Ruby name, where they differ.
  #
  # `send` is the only one, and it has to differ: `Object#send` is Ruby's
  # "call a method by name" and shadowing it on a public object breaks
  # metaprogramming and serialisers.
  RENAMED = { "send" => "send_message" }.freeze

  def test_the_table_covers_the_whole_surface
    assert_equal 55, SURFACE.length, "surface.json declares 55 methods"
  end

  # Response shape per [ns, method], so the fake answers each route the way
  # the route does. `nil` means "not paged": a plain object.
  SHAPES = {
    [:contacts, :list] => :paged,
    [:contacts, :journey] => :paged,
    [:conversations, :list] => :paged,
    [:conversations, :messages] => :paged,
    [:conversations, :unattended] => :paged,
    [:tickets, :list] => :paged,
    [:kb, :articles] => :paged,
    [:search, :query] => :paged,
    [:events, :list] => :paged,
    [:webhooks, :deliveries] => :paged,
    [:macros, :list] => :array
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
