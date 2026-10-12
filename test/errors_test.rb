# frozen_string_literal: true

require_relative "test_helper"

# CONTRACT.md §10.4 -- each status raises its own type, and each carries
# `request_id`.
#
# "A caller must be able to tell 'my key is wrong' from 'my key lacks a
# scope' without parsing a message string."
class ErrorsTest < ChatlyTest
  # The API's real error envelope, from `wireError` in @livechat/shared:
  # `{"error": {"code": ..., "message": ..., "details": {...}}}`.
  def wire(code, message, details = nil)
    body = { "code" => code, "message" => message }
    body["details"] = details unless details.nil?
    { "error" => body }
  end

  def raise_status(status, payload, headers = {})
    transport = FakeTransport.new(FakeTransport.json(status, payload, headers))
    build_client(transport: transport, retries: 1).contacts.get("c_1")
  end

  def test_404_raises_not_found_with_request_id
    error = assert_raises(Chatly::NotFoundError) do
      raise_status(404, wire("not_found", "No such contact"), { "x-request-id" => "req_abc" })
    end

    assert_equal 404, error.status
    assert_equal "not_found", error.code
    assert_equal "No such contact", error.message
    assert_equal "req_abc", error.request_id
    assert_includes error.body, "No such contact"
    refute_predicate error, :retryable?
  end

  def test_422_raises_validation_with_details
    error = assert_raises(Chatly::ValidationError) do
      raise_status(
        422,
        wire("validation_failed", "email: invalid", { "field" => "email" }),
        { "x-request-id" => "req_422" }
      )
    end

    assert_equal 422, error.status
    assert_equal "validation_failed", error.code
    assert_equal({ "field" => "email" }, error.details)
    assert_equal "req_422", error.request_id
  end

  def test_429_raises_rate_limit_with_retry_after_from_the_header
    error = assert_raises(Chatly::RateLimitError) do
      raise_status(
        429,
        wire("rate_limited", "Slow down"),
        { "retry-after" => "7", "x-request-id" => "req_429" }
      )
    end

    assert_equal 429, error.status
    assert_equal 7, error.retry_after
    assert_equal "req_429", error.request_id
    assert_predicate error, :retryable?
  end

  # The API's rate-limit error also carries the wait in the body. A header
  # is not guaranteed to survive every proxy, and a nil `retry_after` on a
  # 429 is the field a caller most needs.
  def test_retry_after_falls_back_to_the_error_body
    error = assert_raises(Chatly::RateLimitError) do
      raise_status(429, wire("rate_limited", "Slow down", { "retryAfterSeconds" => 12 }))
    end

    assert_equal 12, error.retry_after
  end

  def test_retry_after_is_nil_when_the_server_sent_neither
    error = assert_raises(Chatly::RateLimitError) { raise_status(429, wire("rate_limited", "no")) }

    assert_nil error.retry_after
  end

  # An HTTP-date Retry-After is deliberately not parsed into seconds; it
  # must not be misread as a tiny integer either.
  def test_non_numeric_retry_after_header_is_ignored_rather_than_misparsed
    error = assert_raises(Chatly::RateLimitError) do
      raise_status(429, wire("rate_limited", "no"), { "retry-after" => "Wed, 21 Oct 2026 07:28:00 GMT" })
    end

    assert_nil error.retry_after
  end

  def test_401_and_403_are_distinguishable_without_reading_a_message
    auth = assert_raises(Chatly::AuthenticationError) { raise_status(401, wire("unauthorized", "no")) }
    perm = assert_raises(Chatly::PermissionError) { raise_status(403, wire("forbidden", "no scope")) }

    assert_equal 401, auth.status
    assert_equal 403, perm.status
    assert_kind_of Chatly::Error, auth
    assert_kind_of Chatly::Error, perm
    refute_kind_of Chatly::PermissionError, auth
  end

  def test_409_is_a_conflict_and_names_the_idempotency_case
    plain = assert_raises(Chatly::ConflictError) { raise_status(409, wire("conflict", "already linked")) }
    replay = assert_raises(Chatly::ConflictError) do
      raise_status(409, wire("idempotency_conflict", "key reused with a different body"))
    end

    refute_predicate plain, :idempotency_conflict?
    assert_predicate replay, :idempotency_conflict?
  end

  def test_500_is_a_server_error_and_is_retryable
    error = assert_raises(Chatly::ServerError) do
      raise_status(503, wire("unknown", "Internal server error"))
    end

    assert_equal 503, error.status
    assert_predicate error, :retryable?
  end

  # A reverse proxy, a WAF or a 502 page answers with HTML. That must still
  # be a typed error carrying the raw body, not a JSON parse crash.
  def test_a_non_json_error_body_still_produces_a_typed_error
    transport = FakeTransport.new(
      Chatly::Response.new(status: 502, headers: {}, body: "<html>bad gateway</html>")
    )
    error = assert_raises(Chatly::ServerError) do
      build_client(transport: transport, retries: 1).contacts.get("c_1")
    end

    assert_equal 502, error.status
    assert_nil error.code
    assert_equal "HTTP 502", error.message
    assert_equal "<html>bad gateway</html>", error.body
  end

  # A 200 whose body is not JSON is a different failure from a 5xx, and it
  # must not be reported as a transport error -- the request did arrive.
  def test_a_non_json_success_body_raises_rather_than_returning_garbage
    transport = FakeTransport.new(Chatly::Response.new(status: 200, headers: {}, body: "<html>"))
    error = assert_raises(Chatly::Error) do
      build_client(transport: transport, retries: 1).whoami
    end

    assert_equal "sdk_invalid_json_response", error.code
    refute_kind_of Chatly::TransportError, error
  end

  # §3 "A transport failure (DNS, connect, timeout) is its own error type."
  def test_a_connection_failure_is_a_transport_error_with_no_status
    transport = FakeTransport.new(SocketError.new("getaddrinfo: nodename nor servname provided"))
    error = assert_raises(Chatly::TransportError) do
      build_client(transport: transport, retries: 1).whoami
    end

    assert_nil error.status
    assert_match(/SocketError/, error.message)
    assert_predicate error, :retryable?
    # Ruby's own `cause` carries the original, so nothing is lost.
    assert_kind_of SocketError, error.cause
  end

  def test_an_injected_transport_that_raises_anything_still_raises_a_chatly_error
    transport = FakeTransport.new { raise KeyError, "my fake blew up" }
    error = assert_raises(Chatly::TransportError) do
      build_client(transport: transport, retries: 1).whoami
    end

    assert_match(/KeyError/, error.message)
    assert_kind_of KeyError, error.cause
  end

  # A zod failure arrives as an array of issue strings. `["a","b"].to_s` in
  # a backtrace is useless; a joined line is not.
  def test_an_array_message_is_flattened
    error = assert_raises(Chatly::ValidationError) do
      raise_status(422, { "error" => { "code" => "validation_failed",
                                       "message" => ["email: invalid", "name: too long"] } })
    end

    assert_equal "email: invalid; name: too long", error.message
  end

  # Not every error on the path is Chatly's own envelope -- a gateway may
  # answer with a flat `{"code":...}`. Read both.
  def test_a_flat_error_body_is_read_too
    error = assert_raises(Chatly::NotFoundError) do
      raise_status(404, { "code" => "gone", "message" => "nope" })
    end

    assert_equal "gone", error.code
    assert_equal "nope", error.message
  end

  def test_request_id_header_is_matched_case_insensitively
    error = assert_raises(Chatly::NotFoundError) do
      raise_status(404, wire("not_found", "no"), { "X-Request-Id" => "req_mixed" })
    end

    assert_equal "req_mixed", error.request_id
  end

  # Net::HTTP hands back header values as arrays.
  def test_request_id_survives_an_array_header_value
    transport = FakeTransport.new(
      Chatly::Response.new(status: 404, headers: { "x-request-id" => ["req_arr"] }, body: "{}")
    )
    error = assert_raises(Chatly::NotFoundError) do
      build_client(transport: transport, retries: 1).contacts.get("c_1")
    end

    assert_equal "req_arr", error.request_id
  end
end
