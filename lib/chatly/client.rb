# frozen_string_literal: true

module Chatly
  # The Chatly API client.
  #
  #   client = Chatly::Client.new(ENV.fetch("CHATLY_API_KEY"))
  #   client.whoami
  #   client.contacts.upsert(externalId: "user_42", email: "ada@example.com")
  #
  # BACKEND ONLY. The key (`ck_...`) is a bearer credential for an entire
  # workspace -- anything holding it can read every conversation in that
  # workspace. It must never be shipped to a browser, a mobile app, or a
  # source map. The browser SDK is `@chatlychat/sdk-js` and authenticates
  # differently on purpose.
  #
  # Thread safety: a client is immutable after construction and holds no
  # connection state, so sharing one across threads is fine with the default
  # transport (which opens a connection per request). An injected transport
  # is as thread-safe as you make it.
  class Client
    # Production. NOT a dev or example host.
    #
    # Four sibling SDKs shipped with `api.livechat.local` or
    # `api.chatly.example` as the default. Both resolve nowhere, so every
    # call failed for anyone who followed the docs and did not pass a URL,
    # and no test caught it because every test passes one explicitly. A
    # self-hosted install is the only caller that should ever override this.
    DEFAULT_API_URL = "https://api.chatlychat.com"

    # Default request timeout, in seconds, applied to connect, read and
    # write separately.
    DEFAULT_TIMEOUT = 15

    # Namespace reader => resource class.
    #
    # ONE table, and `with_idempotency_key` rebuilds from it. The Node SDK
    # rebound its namespaces by hand onto a derived client and forgot one, so
    # `search` on a derived client still called the parent; building from a
    # table makes that class of bug impossible rather than merely tested.
    NAMESPACES = {
      billing: Resources::Billing,
      channels: Resources::Channels,
      contacts: Resources::Contacts,
      conversations: Resources::Conversations,
      events: Resources::Events,
      kb: Resources::Kb,
      macros: Resources::Macros,
      reports: Resources::Reports,
      search: Resources::Search,
      tickets: Resources::Tickets,
      webhooks: Resources::Webhooks,
      workspace: Resources::Workspace
    }.freeze

    attr_reader :api_url, :pinned_idempotency_key

    # @param api_key [String] the workspace key, `ck_...`. Also accepted as
    #   the `api_key:` keyword, so both of these work:
    #     Chatly::Client.new("ck_live_...")
    #     Chatly::Client.new(api_key: ENV.fetch("CHATLY_API_KEY"))
    # @param api_url [String] base URL; defaults to {DEFAULT_API_URL}
    # @param timeout [Numeric] seconds, default {DEFAULT_TIMEOUT}
    # @param retries [Integer] total attempts including the first, default 3
    # @param retry_policy [Chatly::RetryPolicy, nil] full control; overrides
    #   `retries`
    # @param transport [#call, nil] anything responding to
    #   `call(Chatly::Request) -> Chatly::Response`. This is how the test
    #   suite runs with no network, and how you plug in a pooling HTTP client.
    # @param user_agent [String, nil] override the default UA
    def initialize(key = nil, api_key: nil, api_url: nil, timeout: DEFAULT_TIMEOUT,
                   retries: 3, retry_policy: nil, transport: nil, user_agent: nil)
      # Positional or keyword, because both read naturally in Ruby and
      # neither is worth being strict about. The keyword wins if you pass
      # both.
      key = (api_key || key).to_s
      # Rejected HERE and not at the first call. An unset ENV var is the
      # usual cause, and a client built from one should fail where it was
      # built -- at boot, next to the configuration that is wrong -- not
      # three layers down inside the first request, hours later.
      raise ArgumentError, "Chatly::Client: api_key is required and must not be empty" if key.empty?

      @api_key = key
      @api_url = (api_url.nil? || api_url.to_s.empty? ? DEFAULT_API_URL : api_url.to_s)
      @timeout = timeout
      @pinned_idempotency_key = nil
      @user_agent = user_agent || "chatly-sdk-ruby/#{Chatly::VERSION}"
      @transport = transport || NetHttpTransport.new(timeout: timeout)
      @retry_policy = retry_policy || RetryPolicy.new(attempts: retries)
      @dispatcher = Dispatcher.new(
        api_key: @api_key,
        base_url: @api_url,
        transport: @transport,
        retry_policy: @retry_policy,
        user_agent: @user_agent
      )
    end

    NAMESPACES.each_key do |name|
      # Memoised per instance, built lazily. Lazy construction is what makes
      # `with_idempotency_key` safe: a derived client clears the cache and
      # every namespace is rebuilt against the derived client on first use.
      define_method(name) do
        (@namespaces ||= {})[name] ||= NAMESPACES.fetch(name).new(self)
      end
    end

    # Who is this key?
    #
    # `GET /v1/api-keys/whoami` is deliberately the only route on the
    # api-keys controller that accepts an API key -- managing keys with a key
    # is a privilege-escalation shape.
    #
    # Make it your first call. It turns a mis-scoped key into an obvious
    # error at integration time rather than a 403 from an unrelated endpoint
    # three weeks later:
    #
    #   me = client.whoami
    #   me["workspaceId"]  # => "0192..."
    #   me["scopes"]       # => ["contacts:read", "messages:write", ...]
    def whoami
      request("GET", "/v1/api-keys/whoami")
    end

    # The escape hatch.
    #
    # 140 of the API's 886 routes accept a `ck_` key and only 55 have a typed
    # method here. This reaches the other 85 with the same auth, idempotency,
    # retry and error handling -- so hitting an unwrapped route does not mean
    # abandoning the SDK and hand-rolling HTTP with a bearer token.
    #
    #   client.request("POST", "/v1/tickets/#{id}/time",
    #                  nil, { minutes: 30, note: "call" })
    #
    # @param method [String, Symbol] GET, POST, PUT, PATCH or DELETE
    # @param path [String] starting with `/v1/`
    # @param query [Hash, nil] Array values repeat the key
    # @param body [Hash, Array, nil] JSON-encoded; omit for a read
    # @param idempotency_key [String, nil] overrides the per-call UUID and
    #   the pinned key, for this call only
    # @return [Object, nil] decoded JSON, or nil for 204/empty
    # @raise [Chatly::Error] typed by status; see errors.rb
    def request(method, path, query = nil, body = nil, idempotency_key: nil, headers: {})
      @dispatcher.call(
        method: method,
        path: path,
        query: query,
        body: body,
        idempotency_key: idempotency_key || @pinned_idempotency_key,
        headers: headers
      )
    end

    # Pin one `Idempotency-Key` across writes, for retrying the SAME logical
    # operation.
    #
    # Returns a DERIVED client; this one is unchanged. By default every write
    # mints a fresh UUID, which is what makes an internal retry safe. Pinning
    # is the opposite tool: it tells the API "this is the same operation I
    # already asked for", so same key + same body replays the first response
    # and same key + DIFFERENT body is a 409
    # (`Chatly::ConflictError#idempotency_conflict?`).
    #
    #   key = SecureRandom.uuid
    #   pinned = client.with_idempotency_key(key)
    #   begin
    #     pinned.contacts.upsert(externalId: "user_42")
    #   rescue Chatly::TransportError
    #     pinned.contacts.upsert(externalId: "user_42")  # at most one write
    #   end
    #
    # Use it across process boundaries too: persist the key with the job, and
    # a worker that dies mid-write and is replayed cannot double-write.
    def with_idempotency_key(key)
      unless key.is_a?(String) && !key.empty?
        raise ArgumentError, "with_idempotency_key: key must be a non-empty String"
      end

      copy = dup
      copy.instance_variable_set(:@pinned_idempotency_key, key)
      # Drop the memoised namespaces so each one is rebuilt pointing at
      # `copy`. Without this the derived client's `contacts` would be the
      # parent's object and the pinned key would be silently ignored.
      copy.instance_variable_set(:@namespaces, nil)
      copy
    end

    # Never leak the key into a log line, a `p`, an exception report or a
    # Rails error page. `inspect` is called by more things than you expect.
    def inspect
      "#<Chatly::Client api_url=#{@api_url.inspect} api_key=\"ck_...#{@api_key[-4..] || ''}\" " \
        "pinned_idempotency_key=#{@pinned_idempotency_key.inspect}>"
    end
    alias to_s inspect
  end
end
