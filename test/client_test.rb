# frozen_string_literal: true

require_relative "test_helper"

# CONTRACT.md §10.1, §10.2, §10.3 -- construction, auth, idempotency.
class ClientTest < ChatlyTest
  # §10.1 The default base URL is the production host.
  #
  # The test the four SDKs that shipped `api.livechat.local` /
  # `api.chatly.example` did not have, because every other test in those
  # packages passed an explicit URL.
  def test_default_base_url_is_production
    assert_equal "https://api.chatlychat.com", Chatly::Client::DEFAULT_API_URL

    transport = FakeTransport.new(FakeTransport.json(200, {}))
    Chatly::Client.new(ClientHelpers::TEST_KEY, transport: transport).whoami

    assert_equal "https://api.chatlychat.com/v1/api-keys/whoami", transport.requests.first.url
  end

  def test_default_base_url_is_not_a_dev_or_example_host
    url = Chatly::Client::DEFAULT_API_URL

    refute_match(/\.local\b/, url)
    refute_match(/\.example\b/, url)
    refute_match(/localhost|127\.0\.0\.1/, url)
    assert url.start_with?("https://"), "the default host must be https"
  end

  def test_base_url_override_for_self_hosting
    transport = FakeTransport.new(FakeTransport.json(200, {}))
    client = build_client(transport: transport, api_url: "https://chat.internal.example.net/")
    client.whoami

    # Trailing slash on the base must not produce a doubled slash in the path.
    assert_equal "https://chat.internal.example.net/v1/api-keys/whoami",
                 transport.requests.first.url
  end

  # §10.2 Authorization carries the key.
  def test_authorization_header_carries_the_key
    transport = FakeTransport.new(FakeTransport.json(200, {}))
    build_client(transport: transport).whoami

    headers = transport.requests.first.headers

    assert_equal "Bearer #{ClientHelpers::TEST_KEY}", headers["authorization"]
    assert_equal "application/json", headers["accept"]
    assert_match %r{\Achatly-sdk-ruby/\d+\.\d+\.\d+\z}, headers["user-agent"]
  end

  # §1 "Reject an empty key at construction, not at the first call."
  def test_empty_key_is_rejected_at_construction
    # `ENV["CHATLY_API_KEY"]` set to nothing is the case that matters: it
    # must fail at the line that builds the client, next to the
    # configuration that is wrong, not inside the first request hours later.
    [nil, ""].each do |bad|
      error = assert_raises(ArgumentError) { Chatly::Client.new(bad) }
      assert_match(/api_key is required/, error.message)
    end
    assert_raises(ArgumentError) { Chatly::Client.new(api_key: "") }
  end

  def test_key_accepted_positionally_or_by_keyword
    transport = FakeTransport.new(FakeTransport.json(200, {}), FakeTransport.json(200, {}))
    Chatly::Client.new("ck_one", transport: transport).whoami
    Chatly::Client.new(api_key: "ck_two", transport: transport).whoami

    assert_equal "Bearer ck_one", transport.requests[0].headers["authorization"]
    assert_equal "Bearer ck_two", transport.requests[1].headers["authorization"]
  end

  # The key must not turn up in a log line, an exception report or a Rails
  # error page. `inspect` is called by far more things than you expect.
  def test_inspect_does_not_leak_the_key
    client = Chatly::Client.new("ck_live_super_secret_value")

    refute_includes client.inspect, "super_secret"
    refute_includes client.to_s, "super_secret"
    assert_includes client.inspect, "https://api.chatlychat.com"
  end

  # §10.3 A write sends an Idempotency-Key; two writes send different ones.
  def test_writes_send_a_fresh_idempotency_key_each_time
    transport = FakeTransport.new(FakeTransport.json(201, {}), FakeTransport.json(201, {}))
    client = build_client(transport: transport)
    client.contacts.upsert(email: "a@example.com")
    client.contacts.upsert(email: "b@example.com")

    first = transport.requests[0].headers["idempotency-key"]
    second = transport.requests[1].headers["idempotency-key"]

    refute_nil first
    refute_nil second
    refute_equal first, second, "each write must mint its own key"
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
                 first, "the API accepts a UUIDv4 or a 16-128 char opaque token")
  end

  # §10.3 A pinned key sends the same one twice.
  def test_pinned_idempotency_key_is_reused
    transport = FakeTransport.new(FakeTransport.json(201, {}), FakeTransport.json(201, {}))
    pinned = build_client(transport: transport).with_idempotency_key("pinned-key-1")
    pinned.contacts.upsert(email: "a@example.com")
    pinned.conversations.send_message("conv_1", body: "hi")

    assert_equal "pinned-key-1", transport.requests[0].headers["idempotency-key"]
    assert_equal "pinned-key-1", transport.requests[1].headers["idempotency-key"]
  end

  def test_pinning_returns_a_derived_client_and_leaves_the_original_alone
    transport = FakeTransport.new(FakeTransport.json(201, {}))
    client = build_client(transport: transport)
    pinned = client.with_idempotency_key("abc")

    refute_same client, pinned
    assert_nil client.pinned_idempotency_key
    assert_equal "abc", pinned.pinned_idempotency_key

    client.contacts.upsert(email: "a@example.com")
    refute_equal "abc", transport.requests[0].headers["idempotency-key"]
  end

  # The Node SDK rebound its namespaces onto a derived client one by one and
  # forgot `search`, so a derived client's search methods still called the
  # PARENT. Here they are rebuilt from one table; this proves every single
  # one of them moved.
  def test_every_namespace_on_a_derived_client_points_at_the_derived_client
    client = build_client(transport: FakeTransport.new)

    # Touch every namespace on the PARENT first. This line is the test.
    #
    # Without it the parent's namespace cache is still empty when the client
    # is derived, so the derived client builds its own namespaces whatever
    # `with_idempotency_key` does -- and the assertions below pass against a
    # client that never clears the cache, which is the exact bug they exist
    # to catch. Checked by mutation: removing the cache reset from
    # `with_idempotency_key` failed 0 tests before this line was added.
    Chatly::Client::NAMESPACES.each_key { |name| client.public_send(name) }

    pinned = client.with_idempotency_key("abc")

    Chatly::Client::NAMESPACES.each_key do |name|
      namespace = pinned.public_send(name)

      assert_same pinned, namespace.client,
                  "#{name} on a derived client still points at the parent"
      assert_same client, client.public_send(name).client,
                  "deriving a client must not repoint the ORIGINAL's #{name}"
    end
  end

  # The same bug, caught by consequence rather than by identity: a namespace
  # still closed over the parent sends a fresh UUID instead of the pinned
  # key. Every namespace with a write gets checked, so adding a write to a
  # namespace that is not rebound is caught here too.
  def test_a_pinned_key_reaches_writes_on_every_namespace_that_has_one
    writes = [
      [:contacts, :upsert, [{ email: "a@example.com" }]],
      [:conversations, :send_message, ["v_1", { body: "hi" }]],
      [:tickets, :bulk, [{ ids: ["t_1"], action: "status" }]],
      [:macros, :create, [{ name: "n", scope: "workspace", body: "b" }]],
      [:events, :track, [{ contactId: "c_1", name: "x" }]],
      [:webhooks, :redeliver, ["d_1"]]
    ]
    writes.each do |namespace, method, args|
      transport = FakeTransport.new { |_r, _n| FakeTransport.json(201, {}) }
      client = build_client(transport: transport)
      Chatly::Client::NAMESPACES.each_key { |name| client.public_send(name) }
      client.with_idempotency_key("pin-#{namespace}").public_send(namespace)
            .public_send(method, *args)

      assert_equal "pin-#{namespace}", transport.requests.fetch(0).headers["idempotency-key"],
                   "#{namespace}.#{method} ignored the pinned Idempotency-Key"
    end
  end

  def test_pinning_rejects_a_blank_key
    client = build_client(transport: FakeTransport.new)

    assert_raises(ArgumentError) { client.with_idempotency_key("") }
    assert_raises(ArgumentError) { client.with_idempotency_key(nil) }
  end

  def test_reads_do_not_send_an_idempotency_key
    transport = FakeTransport.new(FakeTransport.json(200, { "items" => [] }))
    build_client(transport: transport).contacts.list

    refute transport.requests.first.headers.key?("idempotency-key")
  end

  def test_delete_is_treated_as_a_write
    transport = FakeTransport.new(FakeTransport.empty(204))
    build_client(transport: transport).macros.delete("macro_1")

    assert_equal "DELETE", transport.requests.first.method
    refute_nil transport.requests.first.headers["idempotency-key"]
  end

  def test_204_decodes_to_nil
    transport = FakeTransport.new(FakeTransport.empty(204))

    assert_nil build_client(transport: transport).macros.delete("macro_1")
  end

  # §2 Query parameters: repeated keys stay repeated.
  def test_query_encoding
    transport = FakeTransport.new(FakeTransport.page([], nil))
    build_client(transport: transport).contacts.list(
      cursor: "abc",
      limit: 50,
      filter: ["status:open", "priority:high"],
      sort: "-createdAt",
      fields: "id,email",
      blocked: false
    )

    query = query_of(transport.requests.first)

    assert_equal "cursor=abc&limit=50&filter=status%3Aopen&filter=priority%3Ahigh" \
                 "&sort=-createdAt&fields=id%2Cemail&blocked=false",
                 query
  end

  def test_nil_query_values_are_dropped_but_false_is_not
    transport = FakeTransport.new(FakeTransport.page([], nil))
    build_client(transport: transport).contacts.list(cursor: nil, blocked: false, limit: 0)

    assert_equal "blocked=false&limit=0", query_of(transport.requests.first)
  end

  # A customer-chosen tag goes into the PATH. `CGI.escape` would turn a space
  # into `+`, which is a literal plus in a path -- a different resource.
  def test_path_segments_are_percent_encoded
    transport = FakeTransport.new(FakeTransport.empty(204))
    build_client(transport: transport).contacts.remove_tag("c_1", "needs follow-up/soon")

    assert_equal "/v1/contacts/c_1/tags/needs%20follow-up%2Fsoon",
                 URI.parse(transport.requests.first.url).path
    refute_includes transport.requests.first.url, "+"
  end

  def test_blank_path_parameters_are_rejected_before_the_request
    client = build_client(transport: FakeTransport.new)

    assert_raises(ArgumentError) { client.contacts.get("") }
    assert_raises(ArgumentError) { client.contacts.get(nil) }
    assert_raises(ArgumentError) { client.contacts.remove_tag("c_1", "") }
  end

  # §8 The escape hatch: 85 of the 140 key-accessible routes have no typed
  # method, and must still be reachable with the same auth and idempotency.
  def test_request_escape_hatch
    transport = FakeTransport.new(FakeTransport.json(201, { "ok" => true }))
    client = build_client(transport: transport)
    result = client.request("POST", "/v1/tickets/t_1/time", { dry: true }, { minutes: 30 })

    request = transport.requests.first

    assert_equal({ "ok" => true }, result)
    assert_equal "POST", request.method
    assert_equal "/v1/tickets/t_1/time", path_of(request)
    assert_equal "dry=true", query_of(request)
    assert_equal({ "minutes" => 30 }, JSON.parse(request.body))
    assert_equal "application/json", request.headers["content-type"]
    refute_nil request.headers["idempotency-key"]
    assert_equal "Bearer #{ClientHelpers::TEST_KEY}", request.headers["authorization"]
  end

  def test_body_keys_are_sent_verbatim
    transport = FakeTransport.new(FakeTransport.json(201, {}))
    build_client(transport: transport).contacts.upsert(
      externalId: "user_42",
      attributes: { "plan_tier" => "pro" }
    )

    # No snake_case/camelCase rewriting in either direction, at any depth:
    # the API's validator drops a key it does not recognise, so a helpful
    # rename would be a silently incomplete write.
    assert_equal({ "externalId" => "user_42", "attributes" => { "plan_tier" => "pro" } },
                 JSON.parse(transport.requests.first.body))
  end

  def test_unsubscribe_defaults_to_unsubscribing_and_can_resubscribe
    transport = FakeTransport.new(FakeTransport.json(200, {}), FakeTransport.json(200, {}))
    client = build_client(transport: transport)
    client.contacts.unsubscribe("c_1")
    client.contacts.unsubscribe("c_1", unsubscribed: false)

    assert_equal({ "unsubscribed" => true }, JSON.parse(transport.requests[0].body))
    assert_equal({ "unsubscribed" => false }, JSON.parse(transport.requests[1].body))
  end

  def test_add_tags_refuses_an_array_rather_than_sending_a_body_the_api_drops
    client = build_client(transport: FakeTransport.new)
    error = assert_raises(ArgumentError) { client.contacts.add_tags("c_1", %w[a b]) }

    assert_match(/one tag per call/, error.message)
  end

  def test_search_requires_a_query_string
    client = build_client(transport: FakeTransport.new)

    assert_raises(ArgumentError) { client.search.query("") }
    assert_raises(ArgumentError) { client.search.query(nil) }
  end

  def test_array_query_values_repeat_the_key_for_search_kinds
    # A page envelope, because `search.query` is paginated and `Chatly::Page`
    # refuses a body that is not one. This test is about the query string, but
    # it still has to answer the way the route does.
    transport = FakeTransport.new(FakeTransport.page([], nil))
    build_client(transport: transport).search.query("password reset", kinds: %w[kb article])

    assert_equal "q=password%20reset&kinds=kb&kinds=article", query_of(transport.requests.first)
  end
end
