# frozen_string_literal: true

require "json"

module Chatly
  # Base class for everything this gem raises.
  #
  # Every error carries the five fields the SDK contract requires, so a caller
  # never has to parse a message string to decide what happened:
  #
  #   status      HTTP status, or nil for a transport failure
  #   code        the API's machine-readable `code`
  #   message     the API's human-readable `message`
  #   request_id  the `x-request-id` response header, when the server sent one
  #   body        the raw response text, for anything the above loses
  #
  # `details` is a sixth, Chatly-specific field: the API's error envelope is
  # `{"error":{"code":…,"message":…,"details":{…}}}` and `details` is where
  # structured context lives (which field failed validation, which plan limit
  # was hit, how many seconds to wait). It is nil when the server omitted it.
  #
  # The originating exception, for a transport failure, is Ruby's own
  # `Exception#cause` -- `TransportError` is always raised from inside a
  # `rescue`, so `err.cause` is the `SocketError`/`Net::ReadTimeout`/etc.
  class Error < StandardError
    attr_reader :status, :code, :request_id, :body, :details

    def initialize(message = nil, status: nil, code: nil, request_id: nil, body: nil, details: nil)
      @status = status
      @code = code
      @request_id = request_id
      @body = body
      @details = details
      super(message || default_message)
    end

    # True for the failures the SDK may safely send again: a connection-level
    # failure, a 429, or a 5xx. Deliberately false for every other 4xx -- a
    # 422 will be a 422 on the second attempt too, and retrying a 409 can
    # turn an honest idempotency conflict into a confusing one.
    def retryable?
      false
    end

    def inspect
      "#<#{self.class.name} status=#{@status.inspect} code=#{@code.inspect} " \
        "request_id=#{@request_id.inspect} message=#{message.inspect}>"
    end

    # Build the right subclass from a response.
    #
    # Reads `{"error":{...}}` first (the shape the API's exception filter
    # actually sends) and falls back to a top-level `{"code":…}` so a
    # reverse proxy's or a future endpoint's flatter error is still typed.
    def self.from_response(status:, headers:, body:)
      parsed = parse_body(body)
      envelope = parsed.is_a?(Hash) ? (parsed["error"].is_a?(Hash) ? parsed["error"] : parsed) : {}
      code = string_or_nil(envelope["code"])
      message = flatten_message(envelope["message"]) || "HTTP #{status}"
      details = envelope["details"].is_a?(Hash) ? envelope["details"] : nil
      request_id = header(headers, "x-request-id")

      kind = class_for(status)
      args = {
        status: status,
        code: code,
        request_id: request_id,
        body: body,
        details: details
      }
      return kind.new(message, retry_after: retry_after_from(headers, details), **args) if kind == RateLimitError

      kind.new(message, **args)
    end

    # Case-insensitive header read. Net::HTTP downcases, an injected
    # transport may not, and `Idempotency-Replay` arrives in mixed case.
    def self.header(headers, name)
      return nil unless headers.respond_to?(:each_pair) || headers.respond_to?(:each)

      wanted = name.downcase
      found = nil
      headers.each do |key, value|
        next unless key.to_s.downcase == wanted

        found = value
        break
      end
      return nil if found.nil?

      found.is_a?(Array) ? found.first&.to_s : found.to_s
    end

    def self.class_for(status)
      case status
      when 401 then AuthenticationError
      when 403 then PermissionError
      when 404 then NotFoundError
      when 409 then ConflictError
      when 422, 400 then ValidationError
      when 429 then RateLimitError
      else status.to_i >= 500 ? ServerError : Error
      end
    end

    def self.parse_body(body)
      return nil if body.nil? || body.to_s.empty?

      JSON.parse(body)
    rescue JSON::ParserError, TypeError
      nil
    end
    private_class_method :parse_body

    def self.string_or_nil(value)
      value.is_a?(String) && !value.empty? ? value : nil
    end
    private_class_method :string_or_nil

    # zod validation failures arrive as an array of issue strings; a single
    # joined line is more useful in a backtrace than `["..."].to_s`.
    def self.flatten_message(value)
      case value
      when String then value.empty? ? nil : value
      when Array then value.empty? ? nil : value.map(&:to_s).join("; ")
      when nil then nil
      else value.to_s
      end
    end
    private_class_method :flatten_message

    def self.retry_after_from(headers, details)
      raw = header(headers, "retry-after")
      if raw && raw.strip.match?(/\A\d+\z/)
        return raw.strip.to_i
      end

      # The API's rate-limit error also puts the wait in the body, as
      # `details.retryAfterSeconds`. Use it when the header is missing or is
      # an HTTP-date we deliberately do not parse (see README).
      seconds = details.is_a?(Hash) ? details["retryAfterSeconds"] : nil
      seconds.is_a?(Numeric) ? seconds.to_i : nil
    end
    private_class_method :retry_after_from

    private

    def default_message
      @status ? "Chatly API error (HTTP #{@status})" : "Chatly request failed"
    end
  end

  # 401 -- the key is missing, malformed, revoked or expired.
  class AuthenticationError < Error; end

  # 403 -- the key is valid but lacks the scope for this route, or the route
  # requires a signed-in person and a workspace key is not a person.
  class PermissionError < Error; end

  # 404 -- no such resource in this workspace. Note that a resource in
  # ANOTHER workspace is also a 404, not a 403: row-level security makes it
  # invisible rather than forbidden.
  class NotFoundError < Error; end

  # 409 -- a conflicting write, including an idempotency-key replay whose
  # body differs from the first attempt's.
  class ConflictError < Error
    # True when this 409 is specifically "you reused an Idempotency-Key with
    # a different body" rather than a domain conflict. Retrying will not help;
    # either send the original body or mint a new key.
    def idempotency_conflict?
      code == "idempotency_conflict"
    end
  end

  # 422 (and 400) -- the request was understood and rejected. `details`
  # usually names the offending field.
  class ValidationError < Error; end

  # 429 -- rate limited. `retry_after` is seconds, from the `Retry-After`
  # header or the error body, and is nil if the server sent neither.
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **kwargs)
      @retry_after = retry_after
      super(message, **kwargs)
    end

    def retryable?
      true
    end
  end

  # 5xx -- the server failed. Safe to retry; the SDK already did, up to the
  # configured attempt count.
  class ServerError < Error
    def retryable?
      true
    end
  end

  # No HTTP response at all: DNS, connect refused, TLS, timeout, a socket
  # closed mid-body -- or an injected transport that raised. `status` is nil,
  # and `cause` is the underlying exception.
  #
  # Distinct from every HTTP status on purpose: "I could not reach the API"
  # and "the API said no" call for different handling.
  class TransportError < Error
    def retryable?
      true
    end
  end
end
