# frozen_string_literal: true

require_relative "test_helper"

# What actually goes on the wire for the methods that HOIST an argument into a
# named field.
#
# `client.knowledge_gaps.update(id, "dismissed")` reads well and is worth
# having, but it means this gem chooses the wire key -- and a wrong key is the
# worst failure this API offers: zod STRIPS an unknown key rather than
# refusing it, so the write succeeds, answers 200, and does nothing. A
# complete server-side implementation plus a misspelled client key is a
# feature that silently never worked. It has happened in this repo: an SDK
# sent `{ tags: [...] }` where the route wanted `{ tag: "..." }` and added no
# tags for as long as nobody checked.
#
# The surface and lock suites cannot see this. They assert the VERB and the
# PATH and the shape of the answer; a method that sent `{ statuz: ... }` would
# pass both. So these tests assert the request, not the canned response.
class WireBodiesTest < ChatlyTest
  def body_of(transport, index = 0)
    raw = transport.requests.fetch(index).body
    raw.nil? ? nil : JSON.parse(raw)
  end

  def send_one(shape = "object")
    transport = FakeTransport.new { |_r, _n| FakeTransport.for_shape(shape) }
    [transport, build_client(transport: transport)]
  end

  # One case per hoisted argument, named with the key the handler reads.
  def test_hoisted_positional_arguments_use_the_field_names_the_handlers_read
    cases = [
      # [declared shape, callable, expected body]
      ["array", ->(c) { c.ai.set_tone([{ category: "warmth", rule: "Be warm" }]) },
       { "rules" => [{ "category" => "warmth", "rule" => "Be warm" }] }],
      ["object", ->(c) { c.ai.generate_tone("A style guide, at length.") },
       { "styleGuide" => "A style guide, at length." }],
      ["object", ->(c) { c.contacts.merge("c_1", "c_2") }, { "mergedId" => "c_2" }],
      ["object", ->(c) { c.tickets.merge("t_1", "t_2") }, { "loserId" => "t_2" }],
      ["object", ->(c) { c.conversations.return_to_bot("v_1", "bot_1") },
       { "botId" => "bot_1" }],
      ["object", ->(c) { c.customer_card_endpoints.create("https://x.test/cards") },
       { "url" => "https://x.test/cards" }],
      ["object", ->(c) { c.knowledge_gaps.update("gap_1", "dismissed") },
       { "status" => "dismissed" }],
      ["object", ->(c) { c.webhooks.set_schema_version("w_1", "2026-10-14") },
       { "schemaVersion" => "2026-10-14" }]
    ]

    cases.each do |shape, call, expected|
      transport, client = send_one(shape)
      call.call(client)

      assert_equal expected, body_of(transport),
                   "the hoisted argument went up under the wrong key"
    end
  end

  # A Hash argument is still accepted, and keyword arguments still win, so the
  # convenience form is not a cage: a field the SDK does not know about has to
  # remain sendable.
  def test_a_hoisted_method_still_accepts_the_whole_body
    transport, client = send_one
    client.knowledge_gaps.update("gap_1", nil, status: "resolved", note: "by hand")

    assert_equal({ "status" => "resolved", "note" => "by hand" }, body_of(transport))
  end

  def test_set_tone_refuses_a_rule_set_that_is_not_an_array_or_missing
    _transport, client = send_one("array")

    assert_raises(ArgumentError) { client.ai.set_tone("be warm") }
    error = assert_raises(ArgumentError) { client.ai.set_tone }

    assert_match(/pass \[\] to delete every rule/, error.message)

    # But the empty set IS a legal request -- it deletes every rule -- so it
    # must not be caught by the same guard.
    transport, client = send_one("array")
    client.ai.set_tone([])

    assert_equal({ "rules" => [] }, body_of(transport))
  end

  # `GET /v1/billing/usage` and `/usage/daily` validate `eventType` against a
  # closed list and throw before reading anything, so a call without one is a
  # 400 and never a summary of everything. Raising locally turns a method that
  # could not succeed into an error at the call site.
  def test_the_usage_meters_require_an_event_type_and_put_it_in_the_query
    _transport, client = send_one
    %i[usage usage_daily].each do |method|
      error = assert_raises(ArgumentError) { client.billing.public_send(method) }

      assert_match(/eventType is required/, error.message)
    end

    transport, client = send_one
    client.billing.usage("ai.tokens", from: "2026-10-01T00:00:00Z")

    assert_equal "eventType=ai.tokens&from=2026-10-01T00%3A00%3A00Z",
                 query_of(transport.requests.first)

    # And the keyword spelling resolves to ONE parameter, not two.
    transport, client = send_one
    client.billing.usage_daily(eventType: "conversation.opened")

    assert_equal "eventType=conversation.opened", query_of(transport.requests.first)
  end

  # Routes whose handler PARSES a body must get one even when the caller sends
  # nothing: `@ZodBody` runs `schema.parse(undefined)` on an absent body, which
  # is a 400. `{}` is the whole fix and it is easy to leave out, because the
  # method works fine against a fake that ignores the body.
  def test_routes_that_parse_a_body_always_send_at_least_an_empty_object
    [
      ->(c) { c.contacts.cards("c_1") },
      ->(c) { c.docs_sources.update("src_1") },
      ->(c) { c.docs_sources.sync("src_1") },
      ->(c) { c.bot_routes.resolve },
      ->(c) { c.conversations.generate_reply("v_1") }
    ].each do |call|
      transport, client = send_one
      call.call(client)

      assert_equal({}, body_of(transport),
                   "this route parses its body, so an absent body is a 400")
      assert_equal "application/json", transport.requests.first.headers["content-type"]
    end
  end

  # And the ones that take no body send none -- not `{}`, not `""`. A body on
  # a route with no `@ZodBody` is ignored, so this is tidiness rather than
  # correctness; the reason it is asserted is that the two groups above and
  # below are easy to confuse, and a reader of the suite should be able to see
  # which route is in which.
  def test_routes_with_no_body_send_no_body
    [
      ->(c) { c.ai.test_provider("openai") },
      ->(c) { c.bots.rotate_external_secret("bot_1") },
      ->(c) { c.bots.test_delivery("bot_1") },
      ->(c) { c.bots.redeliver("bot_1", "del_1") },
      ->(c) { c.channels.rotate_secret("ch_1") },
      ->(c) { c.customer_cards.rotate_secret("card_1") },
      ->(c) { c.customer_card_endpoints.rotate_secret("cce_1") },
      ->(c) { c.customer_card_endpoints.activate_secret("cce_1") },
      ->(c) { c.docs_sources.webhook("src_1") },
      ->(c) { c.knowledge_gaps.draft("gap_1") },
      ->(c) { c.visitors.start_conversation("cont_1") },
      ->(c) { c.webhooks.delete("w_1") }
    ].each do |call|
      transport, client = send_one
      call.call(client)

      request = transport.requests.first

      assert_nil request.body, "this route takes no body"
      assert_nil request.headers["content-type"]
      # Still a write, so it still carries an idempotency key.
      refute_nil request.headers["idempotency-key"]
    end
  end

  # `visitors.start_conversation`, asserted as ONE request rather than as a
  # member of the group above.
  #
  # The group asserts a property across eleven callables and names none of
  # them, so it cannot say that the id reached the PATH -- a method that
  # dropped the argument and posted `/v1/visitors//start-conversation` sends
  # no body and an idempotency key too, and would pass there. This one pins
  # the interpolated path, the verb and the header for the route whose entire
  # input is that one path parameter.
  #
  # And the key is REQUIRED here, not merely honoured: the controller declares
  # `@RequireIdempotencyKey()` at class level and this handler does not opt
  # out, unlike `channels.rotate_secret`. Without the header the API answers
  # 428, so the header is not tidiness -- it is the difference between the
  # call working and not.
  def test_start_conversation_sends_only_the_contact_id_in_the_path
    transport, client = send_one
    client.visitors.start_conversation("cont_1")

    assert_equal 1, transport.requests.length
    request = transport.requests.fetch(0)

    assert_equal "POST", request.method
    assert_equal "/v1/visitors/cont_1/start-conversation", path_of(request)
    assert_nil query_of(request), "this route takes no query parameters"
    assert_nil request.body, "this route takes no body -- not `{}`, not `\"\"`"
    assert_nil request.headers["content-type"], "no body means no content-type"
    refute_nil request.headers["idempotency-key"],
               "the controller requires an Idempotency-Key; without one this is a 428"
  end

  # A contact id with a slash or a space in it must not escape the path
  # segment. The id is the ONLY input this route has, so the escaping is the
  # only input validation there is.
  def test_start_conversation_escapes_the_contact_id_into_one_segment
    transport, client = send_one
    client.visitors.start_conversation("a/b c")

    assert_equal "/v1/visitors/a%2Fb%20c/start-conversation",
                 path_of(transport.requests.fetch(0))
  end

  def test_start_conversation_refuses_an_empty_contact_id_before_calling
    transport, client = send_one

    assert_raises(ArgumentError) { client.visitors.start_conversation("") }
    assert_empty transport.requests, "an empty id must not reach the network"
  end

  # The per-contact 429, in the envelope the server ACTUALLY sends.
  #
  # Worth a test of its own because the shape is counter-intuitive and was
  # described wrongly while this method was being written. The per-contact
  # limit throws `RateLimitedError(ttl)` in
  # `apps/api/.../proactive-outreach-guard.ts`, and `app-exception.filter.ts`
  # sets NO response headers -- it sends `wireError(err.toJSON())` and
  # nothing else. The only thing that synthesises a plain `Retry-After` is an
  # onSend hook in `main.ts` reading the per-bucket headers
  # `@nestjs/throttler` emits, and this refusal does not come from the
  # throttler. So there is no `Retry-After` on it and the wait is only in the
  # body.
  #
  # The fixture therefore sends NO `retry-after` header on purpose. Inventing
  # one would make this test agree with a client that only reads the header,
  # which is the failure it exists to catch: `#retry_after` has to come from
  # `details.retryAfterSeconds` here, and a reader who waits on the header
  # alone has nothing to wait on.
  def test_the_per_contact_limit_carries_its_wait_in_the_body_not_a_header
    response = FakeTransport.json(429, {
                                    "error" => {
                                      "code" => "rate_limited",
                                      "message" => "Too many requests",
                                      "details" => { "retryAfterSeconds" => 1800 }
                                    }
                                  })
    # The premise, asserted rather than assumed: if anyone ever adds a
    # `retry-after` to this fixture, the test below stops proving the body
    # fallback and this line says so instead of passing quietly.
    assert_nil response.headers["retry-after"],
               "the fixture must NOT carry a Retry-After -- that is the whole point"

    transport = FakeTransport.new { |_r, _n| response }
    client = build_client(transport: transport, retries: 1)

    error = assert_raises(Chatly::RateLimitError) do
      client.visitors.start_conversation("cont_1")
    end

    assert_equal 429, error.status
    assert_equal "rate_limited", error.code
    assert_equal 1800, error.retry_after,
                 "retry_after must fall back to details.retryAfterSeconds when the " \
                 "header is absent -- reading the header alone yields nothing to wait on"
    assert_equal 1800, error.details["retryAfterSeconds"]
  end
end
