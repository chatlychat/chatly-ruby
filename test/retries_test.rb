# frozen_string_literal: true

require_relative "test_helper"

# CONTRACT.md §10.5 -- "A 429 is retried and then succeeds; a 400 is NOT
# retried."
#
# §4: retry only connection errors, 429 and 5xx; never a 4xx that is not
# 429; exponential backoff with jitter; honour Retry-After; and a retried
# write reuses the SAME Idempotency-Key as the attempt that failed.
class RetriesTest < ChatlyTest
  def test_429_is_retried_and_then_succeeds
    transport = FakeTransport.new(
      FakeTransport.json(429, { "error" => { "code" => "rate_limited" } }, { "retry-after" => "2" }),
      FakeTransport.json(200, { "workspaceId" => "ws_1" })
    )
    result = build_client(transport: transport).whoami

    assert_equal({ "workspaceId" => "ws_1" }, result)
    assert_equal 2, transport.requests.length
    assert_equal [2.0], slept, "Retry-After must be honoured, not replaced by backoff"
  end

  def test_5xx_is_retried
    transport = FakeTransport.new(
      FakeTransport.json(503, { "error" => { "code" => "unavailable" } }),
      FakeTransport.json(200, { "ok" => true })
    )
    build_client(transport: transport).whoami

    assert_equal 2, transport.requests.length
    # Half jitter with the injected rng: ceiling 0.5 -> 0.25 + 0.125.
    assert_equal [0.375], slept
  end

  def test_a_connection_failure_is_retried
    transport = FakeTransport.new(
      Errno::ECONNRESET.new("peer reset"),
      FakeTransport.json(200, { "ok" => true })
    )
    build_client(transport: transport).whoami

    assert_equal 2, transport.requests.length
  end

  # The one the contract calls out by name.
  def test_400_is_not_retried
    transport = FakeTransport.new(
      FakeTransport.json(400, { "error" => { "code" => "validation_failed", "message" => "bad" } })
    )
    assert_raises(Chatly::ValidationError) { build_client(transport: transport).whoami }

    assert_equal 1, transport.requests.length, "a 400 must not be retried"
    assert_empty slept
  end

  def test_no_other_4xx_is_retried
    { 401 => Chatly::AuthenticationError, 403 => Chatly::PermissionError,
      404 => Chatly::NotFoundError, 409 => Chatly::ConflictError,
      422 => Chatly::ValidationError }.each do |status, kind|
      transport = FakeTransport.new(FakeTransport.json(status, { "error" => { "code" => "x" } }))
      assert_raises(kind) { build_client(transport: transport).whoami }

      assert_equal 1, transport.requests.length, "#{status} must not be retried"
    end
  end

  def test_attempts_are_capped_and_the_last_error_is_raised
    transport = FakeTransport.new(
      *Array.new(3) { FakeTransport.json(503, { "error" => { "code" => "unavailable" } }) }
    )
    assert_raises(Chatly::ServerError) { build_client(transport: transport, retries: 3).whoami }

    assert_equal 3, transport.requests.length, "3 attempts means the first plus two retries"
    assert_equal 2, slept.length
  end

  def test_retries_can_be_turned_off
    transport = FakeTransport.new(FakeTransport.json(503, { "error" => { "code" => "x" } }))
    assert_raises(Chatly::ServerError) { build_client(transport: transport, retries: 1).whoami }

    assert_equal 1, transport.requests.length
  end

  # "A retried write reuses the same Idempotency-Key as the attempt that
  # failed -- that is the whole reason the header exists." Without this, a
  # POST that actually landed upstream before the connection dropped is
  # written twice by the retry.
  def test_a_retried_write_reuses_the_same_idempotency_key
    transport = FakeTransport.new(
      FakeTransport.json(503, { "error" => { "code" => "unavailable" } }),
      FakeTransport.json(201, { "id" => "c_1" })
    )
    build_client(transport: transport).contacts.upsert(email: "a@example.com")

    first = transport.requests[0].headers["idempotency-key"]
    second = transport.requests[1].headers["idempotency-key"]

    refute_nil first
    assert_equal first, second
    # And the body is byte-identical, so the API replays rather than 409s.
    assert_equal transport.requests[0].body, transport.requests[1].body
  end

  def test_backoff_grows_exponentially_and_is_capped
    policy = Chatly::RetryPolicy.new(attempts: 8, base_delay: 0.5, max_delay: 4.0,
                                     rng: ->(_ceiling) { 0.0 })
    # With a zero-jitter rng the delay is exactly half the ceiling, so the
    # progression of ceilings is visible: 0.5, 1, 2, 4, 4 (capped).
    ceilings = (1..5).map { |n| policy.delay_for(attempt: n) * 2 }

    assert_equal [0.5, 1.0, 2.0, 4.0, 4.0], ceilings
  end

  def test_jitter_never_produces_a_zero_or_full_delay
    policy = Chatly::RetryPolicy.new(attempts: 3, base_delay: 1.0)
    delays = Array.new(50) { policy.delay_for(attempt: 1) }

    assert_operator delays.min, :>=, 0.5, "half jitter means the wait is never zero"
    assert_operator delays.max, :<, 1.0
    assert_operator delays.uniq.length, :>, 1, "two clients must not come back together"
  end

  # One upstream header must not be able to park a web request for an hour.
  def test_a_huge_retry_after_is_clamped
    policy = Chatly::RetryPolicy.new(attempts: 3)

    assert_equal Chatly::RetryPolicy::MAX_HONOURED_RETRY_AFTER,
                 policy.delay_for(attempt: 1, retry_after: 3600)
  end

  def test_retry_after_zero_is_honoured_as_zero
    policy = Chatly::RetryPolicy.new(attempts: 3)

    assert_in_delta 0.0, policy.delay_for(attempt: 1, retry_after: 0)
  end

  def test_attempts_below_one_is_rejected
    assert_raises(ArgumentError) { Chatly::RetryPolicy.new(attempts: 0) }
  end
end
