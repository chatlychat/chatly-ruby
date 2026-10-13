# frozen_string_literal: true

# No bundler, no gems. `minitest` ships with Ruby.
require "minitest/autorun"
require "json"
require "uri"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "chatly"

# A transport that never touches a network.
#
# This is the whole reason `Chatly::Client` takes a `transport:` -- no test
# in this suite needs an API key, a running API, or a socket. Either script
# a queue of responses, or pass a block to decide per request.
#
#   t = FakeTransport.new(FakeTransport.json(200, { "ok" => true }))
#   client = build_client(transport: t)
#   client.whoami
#   t.requests.first.headers["authorization"]  # => "Bearer ck_test"
class FakeTransport
  attr_reader :requests

  # @param responses [Array<Chatly::Response, Exception>] consumed in order.
  #   An Exception is raised instead of returned, which is how a connection
  #   failure is simulated.
  def initialize(*responses, &handler)
    @queued = responses.flatten
    @handler = handler
    @requests = []
  end

  def call(request)
    @requests << request
    return @handler.call(request, @requests.length) if @handler

    if @queued.empty?
      raise "FakeTransport: unexpected request #{request.method} #{request.url} " \
            "(the response queue is empty -- the code under test made more " \
            "calls than the test scripted)"
    end

    nxt = @queued.shift
    raise nxt if nxt.is_a?(Exception)

    nxt
  end

  def self.json(status, payload, headers = {})
    Chatly::Response.new(
      status: status,
      headers: { "content-type" => "application/json" }.merge(headers),
      body: payload.is_a?(String) ? payload : JSON.generate(payload)
    )
  end

  def self.empty(status, headers = {})
    Chatly::Response.new(status: status, headers: headers, body: "")
  end

  def self.page(items, next_cursor)
    json(200, { "items" => items, "nextCursor" => next_cursor })
  end

  # A success body of ONE declared shape, exactly as the API sends it.
  #
  # The shape is handed IN by the caller, which is the whole point. The
  # version of this helper that this replaced took a manifest ENTRY and read
  # `paged` (plus a hardcoded list of one bare-array route) off it, so the
  # fake agreed with whatever `surface.json` claimed -- including when it was
  # wrong. `macros.list` was flagged `paged: true` for a day against a
  # handler that is `@PaginationExempt`, two sibling SDKs built paginators
  # over it, and their suites stayed green all the way to a decode error in
  # production, because their fakes answered every route with
  # `{ items, nextCursor }`.
  #
  # So the caller declares the shape by hand (see `EXPECTED_SHAPE` in
  # test/surface_lock_test.rb) and this only renders it.
  SHAPES = %w[array page object empty].freeze

  def self.for_shape(shape, items: [{ "id" => "x_1" }], next_cursor: nil)
    case shape.to_s
    when "page" then page(items, next_cursor)
    when "array" then json(200, items)
    when "object" then json(200, { "id" => "x_1" })
    when "empty"
      # A real 204: no body at all, not an empty string. A decoder that
      # insists on parsing a body fails here, which is why `empty` is its
      # own value rather than "an object you should ignore".
      Chatly::Response.new(status: 204, headers: {}, body: nil)
    else
      raise ArgumentError,
            "FakeTransport.for_shape: #{shape.inspect} is not one of #{SHAPES.join(', ')}"
    end
  end
end

module ClientHelpers
  TEST_KEY = "ck_test_key"

  # A client whose retries do not sleep and whose jitter is deterministic.
  # Both are injected rather than stubbed, so the suite exercises the real
  # RetryPolicy arithmetic without spending wall-clock time in it.
  def build_client(transport:, retries: 3, **options)
    @slept = []
    policy = Chatly::RetryPolicy.new(
      attempts: retries,
      sleeper: ->(seconds) { @slept << seconds },
      rng: ->(ceiling) { ceiling / 2.0 }
    )
    Chatly::Client.new(TEST_KEY, transport: transport, retry_policy: policy, **options)
  end

  # Seconds the client would have slept, in order.
  def slept
    @slept || []
  end

  def path_of(request)
    URI.parse(request.url).path
  end

  def query_of(request)
    URI.parse(request.url).query
  end
end

class ChatlyTest < Minitest::Test
  include ClientHelpers
end
