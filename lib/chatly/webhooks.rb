# frozen_string_literal: true

require "openssl"

module Chatly
  # Default freshness window for a delivery's `t`, in seconds.
  #
  # Five minutes. Without a window the `t` binding buys nothing: someone who
  # captured one delivery could replay those exact bytes forever.
  WEBHOOK_SIGNATURE_TOLERANCE_SECONDS = 300

  # Verify the `x-livechat-signature` header on a webhook delivery.
  #
  # The header is `t=<unix seconds>,v1=<hex>` and `v1` is HMAC-SHA256 over
  # the bytes `<t>.<raw body>` -- the timestamp is bound INTO the digest,
  # which is what makes the replay window enforceable at all.
  #
  # Pass the RAW BODY. Re-serialising parsed JSON reorders keys and changes
  # whitespace, and the digest will not match. In Rails that means
  # `request.raw_post`, not `params`.
  #
  #   # app/controllers/chatly_webhooks_controller.rb
  #   def create
  #     ok = Chatly.verify_webhook_signature(
  #       request.raw_post,
  #       request.headers["X-LiveChat-Signature"],
  #       ENV.fetch("CHATLY_WEBHOOK_SECRET")
  #     )
  #     return head(:unauthorized) unless ok
  #
  #     event = JSON.parse(request.raw_post)
  #     head :ok
  #   end
  #
  # Returns false -- never raises -- for a malformed header, a missing `t` or
  # `v1`, a non-numeric `t`, a stale `t`, or a digest that does not match. A
  # verifier that raises is an accepted webhook in a handler that forgot to
  # rescue, which is the worst possible failure mode for this function.
  #
  # @param body [String] the exact bytes received
  # @param signature_header [String] the `x-livechat-signature` value
  # @param secret [String] the endpoint's `whsec_...` signing secret
  # @param tolerance [Numeric] seconds of clock skew to allow; pass
  #   `Float::INFINITY` only when re-verifying an archived delivery
  # @param now [Integer, nil] unix seconds; an escape hatch for tests
  # @return [Boolean]
  def self.verify_webhook_signature(body, signature_header, secret,
                                    tolerance = WEBHOOK_SIGNATURE_TOLERANCE_SECONDS,
                                    now: nil)
    return false unless body.is_a?(String)
    return false unless signature_header.is_a?(String)
    return false unless secret.is_a?(String) && !secret.empty?

    parts = Webhooks.parse_header(signature_header)
    raw_timestamp = parts["t"]
    provided = parts["v1"]
    return false if raw_timestamp.nil? || provided.nil?
    # Strictly digits. `Integer("17abc")` raises and `"17abc".to_i` returns
    # 17 -- a lenient parse here would accept a header the producer could
    # never have written, and would then compute the digest over a different
    # `t` than the one in the header.
    return false unless raw_timestamp.match?(/\A\d+\z/)

    issued_at = raw_timestamp.to_i
    current = now.nil? ? Time.now.to_i : now.to_i
    return false if (current - issued_at).abs > tolerance

    # Signed over the header's `t` string exactly as it arrived, not over
    # `issued_at.to_s`: a producer that ever wrote `t=0700000000` would sign
    # that string, and re-rendering the integer would not reproduce it.
    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{raw_timestamp}.#{body}")
    Webhooks.secure_compare(expected, provided.downcase)
  end

  # Signature verification. `verify_chatly_signature` and `rack_headers`
  # (defined in `signatures.rb`) are the supported surface of this module;
  # `parse_header` and `secure_compare` below are internals, public so the
  # suite can test the header parser and the comparison on their own.
  module Webhooks
    # Parse `t=...,v1=...` into a Hash.
    #
    # FIRST occurrence of a key wins. That is deliberate: if someone appends
    # `,v1=<digest of their own payload>` to a captured header, a last-wins
    # parse would hand their value to the comparison. Neither value would
    # verify under our secret, but first-wins keeps the behaviour obvious.
    #
    # Unknown fields (a future `v2=`) are collected and ignored, so adding a
    # scheme to the header does not break this verifier.
    def self.parse_header(header)
      out = {}
      header.split(",").each do |part|
        index = part.index("=")
        next if index.nil? || index.zero?

        key = part[0...index].strip
        value = part[(index + 1)..].to_s.strip
        next if key.empty? || value.empty?

        out[key] = value unless out.key?(key)
      end
      out
    end

    # Constant-time string comparison.
    #
    # The length check comes FIRST because `fixed_length_secure_compare`
    # raises `ArgumentError` on a length mismatch -- and this function must
    # not raise. Length is not a secret here: both sides are 64 hex
    # characters of SHA-256, so the only thing a length difference reveals is
    # that the header was malformed.
    def self.secure_compare(expected, provided)
      return false unless expected.bytesize == provided.bytesize

      if OpenSSL.respond_to?(:fixed_length_secure_compare)
        OpenSSL.fixed_length_secure_compare(expected, provided)
      else
        # Ruby < 2.7 / an unusual OpenSSL build. Same guarantee, hand-rolled:
        # XOR every byte pair and OR the results, so the loop runs the same
        # number of iterations and takes the same branches regardless of
        # where the first difference is.
        difference = 0
        expected.bytes.each_with_index { |byte, i| difference |= byte ^ provided.getbyte(i) }
        difference.zero?
      end
    end
  end
end
