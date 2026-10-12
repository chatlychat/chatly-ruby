# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"

module Chatly
  # One HTTP request, as handed to a transport.
  #
  # `headers` keys are already lowercased by the dispatcher. `body` is either
  # nil or an encoded JSON string -- a transport never serialises anything.
  Request = Struct.new(:method, :url, :headers, :body, keyword_init: true)

  # One HTTP response, as returned by a transport.
  #
  # A transport is responsible for exactly this much: status as an Integer,
  # headers as a Hash (any case), body as a String (possibly empty). It must
  # not raise on a 4xx/5xx -- turning a status into an error is the
  # dispatcher's job, and a transport that raised would skip the typing.
  Response = Struct.new(:status, :headers, :body, keyword_init: true) do
    def header(name)
      Error.header(headers, name)
    end
  end

  # The default transport: Ruby's own `net/http`, no gems.
  #
  # A fresh connection per request. That costs a TLS handshake on every call
  # and is the right default anyway: a long-lived pooled connection shared
  # across threads needs synchronisation this gem does not want to own, and
  # `Net::HTTP`'s own persistence is not thread-safe. If you are making
  # thousands of calls and the handshake shows up in a profile, inject a
  # transport backed by a pooling client -- that is what injection is for.
  class NetHttpTransport
    # Network-level failures worth presenting as one error type. Everything
    # here means "no usable HTTP response arrived".
    NETWORK_ERRORS = [
      EOFError,
      Errno::ECONNABORTED,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::EINVAL,
      Errno::ENETUNREACH,
      Errno::EPIPE,
      Errno::ETIMEDOUT,
      IOError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
      Timeout::Error
    ].freeze

    METHODS = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "PUT" => Net::HTTP::Put,
      "PATCH" => Net::HTTP::Patch,
      "DELETE" => Net::HTTP::Delete
    }.freeze

    # @param timeout [Numeric] seconds, applied to connect, read and write
    def initialize(timeout: 15)
      @timeout = timeout
    end

    def call(request)
      uri = URI.parse(request.url)
      klass = METHODS[request.method.to_s.upcase]
      raise ArgumentError, "unsupported HTTP method: #{request.method}" if klass.nil?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout

      req = klass.new(uri.request_uri)
      request.headers.each { |name, value| req[name.to_s] = value.to_s }
      req.body = request.body unless request.body.nil?

      res = http.start { |conn| conn.request(req) }
      Response.new(status: res.code.to_i, headers: res.to_hash, body: res.body.to_s)
    rescue *NETWORK_ERRORS => e
      raise TransportError.new("#{e.class}: #{e.message}", code: "transport_error")
    end
  end

  # How many times, and how long to wait, before giving up.
  #
  # Only connection failures, 429 and 5xx are ever retried (see
  # `Chatly::Error#retryable?`). `attempts` counts the FIRST try, so the
  # default of 3 means at most two retries.
  #
  # `sleeper` and `rng` are injectable so the suite can prove the backoff
  # without spending wall-clock time in it.
  class RetryPolicy
    # Hard ceiling on a server-supplied `Retry-After`, in seconds. Without
    # it, one upstream header could park a web request for an hour.
    MAX_HONOURED_RETRY_AFTER = 60

    attr_reader :attempts, :base_delay, :max_delay

    def initialize(attempts: 3, base_delay: 0.5, max_delay: 8.0,
                   max_retry_after: MAX_HONOURED_RETRY_AFTER,
                   sleeper: nil, rng: nil)
      raise ArgumentError, "attempts must be >= 1" if attempts.to_i < 1

      @attempts = attempts.to_i
      @base_delay = base_delay.to_f
      @max_delay = max_delay.to_f
      @max_retry_after = max_retry_after.to_f
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @rng = rng || ->(ceiling) { Kernel.rand * ceiling }
    end

    # Wait before attempt number `attempt + 1`.
    #
    # Honours `Retry-After` when the server sent one (clamped), otherwise
    # exponential backoff with half jitter: the delay is uniform in
    # [d/2, d), so two clients that failed together do not come back
    # together, and the wait is never zero.
    def wait(attempt:, retry_after: nil)
      @sleeper.call(delay_for(attempt: attempt, retry_after: retry_after))
    end

    def delay_for(attempt:, retry_after: nil)
      if retry_after.is_a?(Numeric) && retry_after >= 0
        return [retry_after.to_f, @max_retry_after].min
      end

      ceiling = [@base_delay * (2**(attempt - 1)), @max_delay].min
      (ceiling / 2.0) + @rng.call(ceiling / 2.0)
    end
  end

  # Auth, URL building, idempotency, retries, error typing, JSON decoding.
  #
  # Everything that is the same for all 55 methods lives here exactly once;
  # a resource class only knows a verb and a path.
  class Dispatcher
    # Verbs that must carry an `Idempotency-Key`. DELETE is in the list: the
    # API requires the header on every write, and a retried DELETE without
    # one can turn "deleted" into "404" on the second attempt.
    WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze

    attr_reader :base_url

    def initialize(api_key:, base_url:, transport:, retry_policy:, user_agent:)
      @api_key = api_key
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @transport = transport
      @retry_policy = retry_policy
      @user_agent = user_agent
    end

    # @return [Object, nil] decoded JSON, or nil for 204/empty
    def call(method:, path:, query: nil, body: nil, idempotency_key: nil, headers: {})
      verb = method.to_s.upcase
      write = WRITE_METHODS.include?(verb)
      payload = body.nil? ? nil : JSON.generate(body)

      request_headers = base_headers
      request_headers["content-type"] = "application/json" unless payload.nil?
      # Mint a fresh key per call so an SDK-level retry cannot double-write;
      # a pinned key (Client#with_idempotency_key) is how you deliberately
      # retry the SAME logical operation.
      request_headers["idempotency-key"] = (idempotency_key || SecureRandom.uuid) if write
      headers.each { |name, value| request_headers[name.to_s.downcase] = value.to_s }

      request = Request.new(
        method: verb,
        url: build_url(path, query),
        headers: request_headers,
        body: payload
      )

      run_with_retries(request)
    end

    def build_url(path, query = nil)
      url = "#{@base_url}#{path}"
      encoded = encode_query(query)
      encoded.empty? ? url : "#{url}?#{encoded}"
    end

    # `cursor`, `limit`, `filter`, `sort`, `fields` -- plus anything an
    # endpoint takes. An Array value repeats the key (`filter=a&filter=b`)
    # rather than comma-joining it, because comma-joining is a different
    # request: the API reads repeated keys as a list and a comma as part of
    # one value. nil values are dropped; `false` and `0` are not.
    def encode_query(query)
      return "" if query.nil? || (query.respond_to?(:empty?) && query.empty?)

      pairs = []
      query.each do |key, value|
        next if value.nil?

        name = escape(key.to_s)
        if value.is_a?(Array)
          value.each { |item| pairs << "#{name}=#{escape(stringify(item))}" unless item.nil? }
        else
          pairs << "#{name}=#{escape(stringify(value))}"
        end
      end
      pairs.join("&")
    end

    # Percent-encode one path segment.
    #
    # Hand-rolled rather than `CGI.escape`, which encodes a space as `+`:
    # `+` means a space in a query string and a literal plus in a path, so
    # `CGI.escape` on a path segment silently changes the resource you asked
    # for. A tag named `needs follow-up` is a real case -- see
    # `contacts.remove_tag`.
    def self.escape_segment(value)
      value.to_s.b.gsub(/[^a-zA-Z0-9\-_.~]/) { |byte| format("%%%02X", byte.ord) }
    end

    private

    def base_headers
      {
        "authorization" => "Bearer #{@api_key}",
        "accept" => "application/json",
        "user-agent" => @user_agent
      }
    end

    def escape(value)
      self.class.escape_segment(value)
    end

    def stringify(value)
      case value
      when true then "true"
      when false then "false"
      when Time then value.utc.iso8601
      else value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
      end
    end

    def run_with_retries(request)
      attempt = 0
      loop do
        attempt += 1
        begin
          response = invoke(request)
        rescue TransportError => e
          raise e unless attempt < @retry_policy.attempts

          @retry_policy.wait(attempt: attempt)
          next
        end

        return decode(response) if response.status < 400

        error = Error.from_response(
          status: response.status,
          headers: response.headers,
          body: response.body
        )
        raise error unless error.retryable? && attempt < @retry_policy.attempts

        # The same Idempotency-Key goes out again -- `request` is reused
        # verbatim. That is the entire reason the header exists: without it a
        # retried POST that actually succeeded upstream would write twice.
        @retry_policy.wait(
          attempt: attempt,
          retry_after: error.is_a?(RateLimitError) ? error.retry_after : nil
        )
      end
    end

    def invoke(request)
      response = @transport.call(request)
      return response if response.respond_to?(:status) && response.respond_to?(:body)

      raise TransportError.new(
        "transport returned #{response.class}, expected a response with #status and #body",
        code: "transport_contract"
      )
    rescue Chatly::Error
      raise
    rescue StandardError => e
      # An injected transport can raise anything. Wrapping it keeps the
      # promise that this gem only ever raises Chatly::Error, and `cause`
      # still carries the original for anyone debugging their own transport.
      raise TransportError.new("#{e.class}: #{e.message}", code: "transport_error")
    end

    def decode(response)
      body = response.body
      return nil if response.status == 204 || body.nil? || body.to_s.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      raise Error.new(
        "Chatly returned HTTP #{response.status} with a body that is not JSON",
        status: response.status,
        code: "sdk_invalid_json_response",
        request_id: Error.header(response.headers, "x-request-id"),
        body: body.to_s
      )
    end
  end
end
