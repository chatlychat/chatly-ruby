# frozen_string_literal: true

require "openssl"

require_relative "signature_text"

# Minting a v2 signature -- the other direction from `signatures.rb`.
#
# A port of `signChatlyV2` / `chatlyV2BaseString` from the Node SDK
# (`packages/sdk-node/src/signature-mint.ts` in the monorepo), which is the
# reference: where this file and that one disagree about the bytes, that one is
# right and this one has a bug.
#
# Verifying is what a customer's handler does, and it lives next door. Minting
# is what a TEST does -- standing up a fake Chatly and firing a signed request
# at your own endpoint -- and until this file existed a Ruby integrator writing
# that test had to re-derive `<t>.<METHOD>.<path>.<rawBody>` by hand from the
# documentation. A hand-derived base string is the one thing a signature test
# must not have: get it wrong the same way in the test and nowhere else, and
# the test passes while production refuses every delivery. `packages/shared`
# shipped the mirror image of that once -- a header in milliseconds over a
# seconds value -- and a verifier following our own published docs refused 100%
# of real traffic.
#
# Its own file because `signatures.rb` is 571 lines against the repository's
# 650-line ceiling, which is the same reason the Node reference split it out.
#
# It is deliberately NOT for signing real outbound traffic: nothing in this gem
# sends a signed request to a customer. Chatly's own producers are
# `packages/shared/src/webhook-signature/v2.ts`.
#
# == The marker, which is why `base:` has no default
#
# `sign_chatly_v2` emits `b=t` for the unified base and `b=b` for the body
# base, and there is no default: the two constructions are indistinguishable
# from the value alone, which is precisely why the marker exists, so a caller
# has to say which one it means. An ABSENT marker means the BODY base -- every
# v2 signature Chatly minted before the marker existed was `<t>.<rawBody>` --
# and this method never emits an absent one.
#
# The one wire value it cannot produce on its own is the workflow action's
# current dual-digest form, `t=<T>,v1=<target>,v1=<body>` with no marker. That
# is built from two mints by taking the `v1=` field out of each, which is what
# the producer itself does (`digestOf` in
# `apps/worker/src/handlers/action-handlers/fire-webhook.ts`);
# `test/signature_mint_test.rb` does the same and verifies the result.
module Chatly
  # Which string a v2 signature was taken over. "target" is the unified base
  # `<t>.<METHOD>.<path>.<rawBody>`; "body" is `<t>.<rawBody>`.
  V2_MINT_BASES = %w[target body].freeze

  # Sugar for `Chatly::Webhooks.sign_chatly_v2`, beside
  # `Chatly.verify_chatly_signature`.
  def self.sign_chatly_v2(**kwargs)
    Webhooks.sign_chatly_v2(**kwargs)
  end

  # Sugar for `Chatly::Webhooks.chatly_v2_base_string`.
  def self.chatly_v2_base_string(**kwargs)
    Webhooks.chatly_v2_base_string(**kwargs)
  end

  module Webhooks
    # The exact bytes the MAC is taken over, so a test can pin them.
    #
    # `base: "target"` gives `<t>.<METHOD>.<path>.<rawBody>` and
    # `base: "body"` gives `<t>.<rawBody>`. The method is upper-cased, as the
    # verifier upper-cases it; `path` is `pathname + query` of the request line
    # and never the scheme or host.
    #
    # Returns a BINARY (ASCII-8BIT) String where the Node reference returns a
    # JavaScript string, because the MAC is over bytes and a body is not always
    # valid UTF-8 text. For a UTF-8 body the two hold the same bytes.
    #
    # Raises ArgumentError when `base` is not one of `V2_MINT_BASES`, when
    # `base: "target"` is given no method or path, or when the timestamp is not
    # a non-negative Integer. Those are refusals rather than guesses: an empty
    # method or path signs a string the receiver cannot reproduce, which
    # reaches them as "signature mismatch" and sends them hunting their own
    # secret. TypeScript's types make the first unreachable in the reference,
    # and every production caller there refuses before minting --
    # `chatlyV2SigningPath` returns null on a URL that will not parse and the
    # CLI stops -- so this raises where the reference merely never gets the
    # chance to.
    def self.chatly_v2_base_string(base:, timestamp_seconds:, body:, method: nil, path: nil)
      unless V2_MINT_BASES.include?(base)
        raise ArgumentError, "base: must be \"target\" or \"body\", got #{base.inspect}. There is " \
                             "no default: the two constructions are indistinguishable without " \
                             "the marker sign_chatly_v2 emits."
      end
      t = checked_timestamp(timestamp_seconds)
      raw = raw_bytes(body)
      return "#{t}.".b + raw if base == "body"

      unless method.is_a?(String) && !method.empty?
        raise ArgumentError, 'base: "target" signs the METHOD, so method: is required'
      end
      unless path.is_a?(String) && !path.empty?
        raise ArgumentError, 'base: "target" signs the path, so path: is required -- pathname + ' \
                             "query of the request line, not the scheme or host"
      end

      # Assembled piece by piece, exactly as `base_prefix` in `signatures.rb`
      # does, and for its reason: interpolating a non-UTF-8 path into a UTF-8
      # literal raises Encoding::CompatibilityError, and taking the whole
      # interpolation `.b` afterwards would be a DIFFERENT byte string from
      # what the verifier builds for the same path. Same pieces, same order,
      # same conversions -- or the round-trip test is the only thing standing
      # between a mint and a value nothing verifies.
      "#{t}.".b + utf8_bytes(method.upcase) + ".".b + utf8_bytes(path) + ".".b + raw
    end

    # The `x-chatly-signature-v2` value for one request: `t=...,v1=...,b=...`.
    #
    #   header = Chatly.sign_chatly_v2(
    #     base: "target", secret: secret, timestamp_seconds: 1_760_000_000,
    #     method: "POST", path: "/hooks/chatly", body: raw
    #   )
    #   # => "t=1760000000,v1=<64 hex>,b=t"
    #
    #   Chatly.verify_chatly_signature(
    #     surface: "unified_v2", body: raw, secret: secret,
    #     headers: { "x-chatly-signature-v2" => header },
    #     method: "POST", path: "/hooks/chatly"
    #   ).ok? # => true
    #
    # `timestamp_seconds:` is unix SECONDS, never milliseconds. Two surfaces
    # send millisecond timestamps in their LEGACY headers; the v2 header is
    # seconds on every one of them.
    #
    # An empty secret is refused: an empty String is a perfectly valid HMAC
    # key, which is the problem, and the likeliest cause is an environment
    # variable that never got set.
    def self.sign_chatly_v2(base:, secret:, timestamp_seconds:, body:, method: nil, path: nil)
      # The verifier hands OpenSSL the secret String as it stands, so this
      # takes its bytes the same way. Through the same helper only for the
      # type check: a non-String key is an opaque ArgumentError out of
      # OpenSSL rather than a sentence that says what to pass.
      key = raw_bytes(secret)
      raise ArgumentError, "secret: must not be empty" if key.empty?

      message = chatly_v2_base_string(
        base: base, timestamp_seconds: timestamp_seconds, body: body, method: method, path: path
      )
      digest = OpenSSL::HMAC.hexdigest("SHA256", key, message)
      "t=#{timestamp_seconds},v1=#{digest},b=#{base == 'target' ? 't' : 'b'}"
    end

    # `true` and `false` are not Integers in Ruby, so unlike Python there is no
    # `true` -> "1" trap here; a Float is the one that bites, because
    # `1_760_000_000.0.to_s` is "1760000000.0" and the verifier's `t` must be a
    # run of digits. The digest would then be over text no verifier can
    # reproduce, and it would arrive as "signature mismatch".
    def self.checked_timestamp(timestamp_seconds)
      unless timestamp_seconds.is_a?(Integer)
        raise ArgumentError, "timestamp_seconds: must be an Integer of unix SECONDS, got " \
                             "#{timestamp_seconds.class}"
      end
      raise ArgumentError, "timestamp_seconds: must not be negative" if timestamp_seconds.negative?

      timestamp_seconds.to_s
    end
    private_class_method :checked_timestamp

    # A String's bytes AS THEY ARE -- `.b`, matching the verifier, which takes
    # `body.b` and not `utf8_bytes(body)`.
    #
    # The asymmetry with the method and path above is deliberate and copied
    # from `signatures.rb`: a body is whatever arrived on the wire, so
    # transcoding it would change the bytes being MACed, while a method and a
    # path are text and are taken as their UTF-8 encoding. Minting with the
    # wrong one of the two would produce a value this gem's own verifier
    # refuses, which is what the round-trip in `signature_mint_test.rb`
    # exists to catch.
    def self.raw_bytes(value)
      unless value.is_a?(String)
        raise ArgumentError, "expected a String of raw bytes, got #{value.class} -- pass the " \
                             "exact bytes that will be sent, not a parsed object"
      end

      value.b
    end
    private_class_method :raw_bytes
  end
end
