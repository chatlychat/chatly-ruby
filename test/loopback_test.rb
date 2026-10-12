# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# The one test that exercises the REAL transport.
#
# Everything else injects a fake, which proves the SDK's own logic and
# nothing about `net/http`. A fake cannot catch a wrong request line, a
# header the library refuses to send, a body that never gets written, or a
# response whose status we read from the wrong place. So this stands up a
# plain `TCPServer` on 127.0.0.1, speaks the minimum HTTP/1.1 needed, and
# drives `Chatly::NetHttpTransport` against it.
#
# Still no network: the socket is bound to the loopback interface on an
# ephemeral port, there is no API key beyond a test string, and nothing
# outside this process is contacted.
class LoopbackTest < ChatlyTest
  # One request, one response, then the server closes.
  #
  # @yieldparam request [String] the raw request text we received
  # @return [Thread] joined by the caller for the captured request
  def serve(status_line, headers, body)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = nil

    thread = Thread.new do
      socket = server.accept
      # Read the request head, then exactly Content-Length bytes of body.
      head = +""
      head << socket.gets.to_s until head.end_with?("\r\n\r\n")
      length = head[/^content-length:\s*(\d+)/i, 1].to_i
      payload = length.positive? ? socket.read(length) : ""
      captured = head + payload

      response_headers = headers.merge("content-length" => body.bytesize.to_s,
                                       "connection" => "close")
      socket.write("HTTP/1.1 #{status_line}\r\n")
      response_headers.each { |k, v| socket.write("#{k}: #{v}\r\n") }
      socket.write("\r\n")
      socket.write(body)
      socket.close
      server.close
      captured
    end

    [port, thread]
  end

  def client_for(port, **options)
    Chatly::Client.new(
      ClientHelpers::TEST_KEY,
      api_url: "http://127.0.0.1:#{port}",
      timeout: 5,
      retries: 1,
      **options
    )
  end

  def test_a_real_get_over_net_http
    port, thread = serve("200 OK", { "content-type" => "application/json",
                                     "x-request-id" => "req_loop" },
                         '{"items":[{"id":"c_1"}],"nextCursor":null}')
    page = client_for(port).contacts.list(limit: 2, filter: %w[status:open vip])
    raw = thread.value

    assert_equal 1, page.size
    assert_nil page.next_cursor

    # The request line, verbatim, including the repeated query key.
    assert_includes raw, "GET /v1/contacts?limit=2&filter=status%3Aopen&filter=vip HTTP/1.1\r\n"
    assert_match(/^authorization: Bearer #{ClientHelpers::TEST_KEY}\r$/i, raw)
    assert_match(%r{^accept: application/json\r$}i, raw)
    assert_match(%r{^user-agent: chatly-sdk-ruby/\d+\.\d+\.\d+\r$}i, raw)
    refute_match(/^idempotency-key:/i, raw)
  end

  def test_a_real_post_sends_the_body_and_an_idempotency_key
    port, thread = serve("201 Created", { "content-type" => "application/json" },
                         '{"id":"c_1"}')
    result = client_for(port).contacts.upsert(externalId: "user_42", email: "a@example.com")
    raw = thread.value

    assert_equal({ "id" => "c_1" }, result)
    assert_includes raw, "POST /v1/contacts HTTP/1.1\r\n"
    assert_match(%r{^content-type: application/json\r$}i, raw)
    assert_match(/^idempotency-key: [0-9a-f-]{36}\r$/i, raw)
    assert_includes raw, '{"externalId":"user_42","email":"a@example.com"}'
  end

  def test_a_real_404_is_typed_and_carries_the_request_id
    port, thread = serve("404 Not Found", { "content-type" => "application/json",
                                            "x-request-id" => "req_404" },
                         '{"error":{"code":"not_found","message":"No such contact"}}')
    error = assert_raises(Chatly::NotFoundError) { client_for(port).contacts.get("nope") }
    thread.value

    assert_equal 404, error.status
    assert_equal "not_found", error.code
    assert_equal "req_404", error.request_id
  end

  def test_a_real_204_decodes_to_nil
    port, thread = serve("204 No Content", {}, "")

    assert_nil client_for(port).macros.delete("m_1")
    assert_includes thread.value, "DELETE /v1/macros/m_1 HTTP/1.1\r\n"
  end

  # Nothing is listening on this port, so this is the connect-refused path
  # through the real transport -- the one place `TransportError` is produced
  # by `net/http` rather than by an injected fake.
  def test_a_refused_connection_is_a_transport_error
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    error = assert_raises(Chatly::TransportError) { client_for(port).whoami }

    assert_nil error.status
    assert_kind_of SystemCallError, error.cause
  end

  def test_the_default_transport_is_net_http
    client = Chatly::Client.new("ck_test")

    assert_kind_of Chatly::NetHttpTransport,
                   client.instance_variable_get(:@transport)
  end
end
