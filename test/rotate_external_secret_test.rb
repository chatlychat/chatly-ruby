# frozen_string_literal: true

require_relative "test_helper"

# `bots.rotate_external_secret(id, activate_at:)` -- the optional overlap
# window on `POST /v1/bots/{id}/external/rotate-secret`.
#
# The route's body schema is `.strict()`: `activate_at` (snake_case) is a 400,
# and an absent body is the old hard cut. So the KEY SPELLING and the
# PRESENCE of the body are the whole contract, and both are asserted on the
# bytes this gem sent -- a fake that answered `activatesAt` regardless would
# agree with a client that sent nothing at all.
class RotateExternalSecretTest < ChatlyTest
  PATH = "/v1/bots/bot_1/external/rotate-secret"

  def capture(response = FakeTransport.json(201, { "signingSecret" => "whsec_x", "activatesAt" => nil }))
    transport = FakeTransport.new { |_r, _n| response }
    client = build_client(transport: transport)
    result = yield client
    assert_equal 1, transport.requests.length
    [transport.requests.first, result]
  end

  def test_a_string_activate_at_goes_up_verbatim_under_the_camel_case_key
    request, = capture do |c|
      c.bots.rotate_external_secret("bot_1", activate_at: "2026-10-16T09:00:00+02:00")
    end

    assert_equal "POST", request.method
    assert_equal PATH, path_of(request)
    assert_nil query_of(request)
    refute_nil request.headers["idempotency-key"], "a write carries an Idempotency-Key"
    assert_equal "application/json", request.headers["content-type"]

    decoded = JSON.parse(request.body)

    assert_equal({ "activateAt" => "2026-10-16T09:00:00+02:00" }, decoded,
                 "the body must be exactly one key, camelCase, value untouched")
    refute decoded.key?("activate_at"), "snake_case is a 400 on a .strict() schema"
    assert_equal ["activateAt"], decoded.keys
  end

  def test_a_time_is_sent_as_the_utc_z_instant_with_milliseconds
    request, = capture do |c|
      c.bots.rotate_external_secret("bot_1", activate_at: Time.utc(2026, 10, 16, 9, 0, 0, 123_000))
    end

    assert_equal({ "activateAt" => "2026-10-16T09:00:00.123Z" }, JSON.parse(request.body))
  end

  def test_a_non_utc_time_is_converted_to_the_same_instant_in_utc
    local = Time.new(2026, 10, 16, 11, 0, 0, "+02:00")
    request, = capture { |c| c.bots.rotate_external_secret("bot_1", activate_at: local) }

    assert_equal({ "activateAt" => "2026-10-16T09:00:00.000Z" }, JSON.parse(request.body),
                 "11:00+02:00 is 09:00Z; an unconverted offset or a wall-clock Z is wrong")
    # And the caller's Time is not mutated by the conversion.
    assert_equal 7200, local.utc_offset
  end

  # The no-argument call, byte for byte what it sent before the window
  # existed: no body, no content-type, still an idempotency key. (Also in
  # `WireBodiesTest#test_routes_with_no_body_send_no_body`; asserted here on
  # its own so that a regression names this method.)
  def test_without_activate_at_no_body_goes_up
    request, = capture { |c| c.bots.rotate_external_secret("bot_1") }

    assert_equal "POST", request.method
    assert_equal PATH, path_of(request)
    assert_nil request.body, "the hard cut sends no body -- not `{}`"
    assert_nil request.headers["content-type"]
    refute_nil request.headers["idempotency-key"]

    explicit_nil, = capture { |c| c.bots.rotate_external_secret("bot_1", activate_at: nil) }

    assert_nil explicit_nil.body, "activate_at: nil is the same as absent"
  end

  def test_a_value_that_is_neither_a_time_nor_a_string_is_refused_before_sending
    transport = FakeTransport.new { |_r, _n| raise "must not be called" }
    client = build_client(transport: transport)

    assert_raises(ArgumentError) do
      client.bots.rotate_external_secret("bot_1", activate_at: 1_760_000_000)
    end
    assert_empty transport.requests
  end

  # The weak one: the answer is handed back undecorated.
  def test_the_answer_exposes_activates_at_both_ways
    _, deferred = capture(FakeTransport.json(201, { "signingSecret" => "whsec_x",
                                                    "activatesAt" => "2026-10-16T09:00:00.000Z" })) do |c|
      c.bots.rotate_external_secret("bot_1", activate_at: "2026-10-16T09:00:00.000Z")
    end

    assert_equal "whsec_x", deferred["signingSecret"]
    assert_equal "2026-10-16T09:00:00.000Z", deferred["activatesAt"]

    _, immediate = capture { |c| c.bots.rotate_external_secret("bot_1") }

    assert immediate.key?("activatesAt")
    assert_nil immediate["activatesAt"], "null means the new secret is already signing"
  end
end
