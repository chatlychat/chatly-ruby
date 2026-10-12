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

  # The response SHAPE a given manifest entry's route actually returns.
  #
  # This exists because of a bug in two sibling SDKs: their fake transports
  # answered EVERY route with a page envelope, so a client that wrongly
  # wrapped a cursorless route in a page object looked fine in tests and
  # raised a decode error in real use. A fake that answers every route the
  # same way can only test the SDK against itself.
  #
  # So the shape comes from the manifest entry: `paged` gets a page envelope,
  # a route documented as returning a bare array gets a bare array, and
  # everything else gets a plain object.
  BARE_ARRAY_ROUTES = [%w[macros list]].freeze

  def self.for_entry(entry, items: [], next_cursor: nil)
    key = [entry["ns"], entry["name"]]
    return page(items, next_cursor) if entry["paged"]
    return json(200, items) if BARE_ARRAY_ROUTES.include?(key)

    json(200, {})
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
