# frozen_string_literal: true

require "openssl"

require_relative "signature_text"

# One verifier for every signature Chatly puts on an outbound request.
#
# A port of `verifyChatlySignature` in `packages/sdk-node/src/signatures.ts`,
# which is the reference: where this file and that one disagree, that one is
# right and this one has a bug. Both run the same cross-SDK corpus
# (`test/fixtures/signature_vectors.json`, byte-identical in every SDK), so a
# disagreement shows up as a red vector rather than as a rejected delivery.
#
# ═══ WHY IT TAKES A `surface:` ═══════════════════════════════════════════
#
# Because the header name does not determine the construction. Three
# surfaces send `x-chatly-signature` and sign three different strings, and
# two of the eight send MILLISECONDS where the rest send seconds. The caller
# knows which route they are terminating; this function cannot guess it from
# the request without guessing wrong some of the time.
#
# ═══ THE UNIFIED v2 CONSTRUCTION ═════════════════════════════════════════
#
# `x-chatly-signature-v2: t=<unix seconds>,v1=<hex>` over
# `<t>.<METHOD>.<path>.<raw body>` is where every surface is going, sent
# alongside each one's legacy header. `v2:` chooses how hard to insist:
#
#   - "prefer" (default) -- if the v2 header is present AND `method:` and
#     `path:` were given, verify THAT and nothing else; otherwise verify the
#     surface's own construction. A receiver that passes method and path
#     gets the stronger check the day the sender starts emitting v2, with no
#     code change.
#   - "require" -- refuse unless the v2 header is there.
#   - "ignore" -- the surface's own construction only.
#
# "prefer" never cross-falls-back: once v2 is chosen, a mismatched v2 digest
# is a refusal, not a reason to try the legacy header. Both headers are
# minted from the same secret, so a good legacy digest beside a bad v2 one is
# tampering or a sender bug, and accepting it would hide both.
#
# ═══ WHY IT RETURNS A RESULT INSTEAD OF A BOOLEAN ════════════════════════
#
# `Chatly.verify_webhook_signature` returns `false` for nine different
# failures, and an integrator cannot tell "your clock is wrong" from "your
# secret is wrong" from "you passed the parsed body". This returns a
# `Chatly::SignatureResult` whose `reason` is a stable string to branch on and
# whose `message` is a sentence written to be logged.
#
# ═══ WHY IT NEVER RAISES ═════════════════════════════════════════════════
#
# CONTRACT.md §6: a verifier that raises is an accepted webhook in a handler
# that forgot to rescue. Every input -- nil, a Hash where a String belongs,
# an Integer header value -- comes back `ok? == false`. The decision code is
# written not to raise at all; the `rescue` at the bottom is a backstop, and
# it maps to `signature_mismatch` so that a bug in here can only ever refuse.
module Chatly
  # Freshness window for every surface, in SECONDS whatever unit the
  # surface's own timestamp is in. Applies in both directions.
  SIGNATURE_TOLERANCE_SECONDS = 300

  # The unified header every surface is moving to.
  V2_SIGNATURE_HEADER = "x-chatly-signature-v2"

  # Sentinel for "the timestamp is the `t=` field of the signature value",
  # as opposed to the name of a separate header.
  IN_SIGNATURE = :in_signature
  private_constant :IN_SIGNATURE

  # The surface table. Keys are the surface names `surface:` accepts (as a
  # String or a Symbol).
  #
  # - `header`        -- where the digest is
  # - `timestamp`     -- `IN_SIGNATURE` (the `t=` field), a header name, or nil
  # - `format`        -- "tv1" (`t=...,v1=...`) or "sha256" (`sha256=<hex>`)
  # - `unit`          -- "seconds", "milliseconds", or nil (no timestamp)
  # - `base`          -- what the MAC is over: "body" `<t>.<raw body>`,
  #                      "target" `<t>.<METHOD>.<path>.<raw body>`,
  #                      "body_only" `<raw body>`
  # - `also_target`   -- workflow_webhook only: it sent the v2 header BEFORE
  #                      the base gained the method and path, so both bases
  #                      are live on it at once
  # - `describe`      -- quoted into error messages
  #
  # The two traps are `canvas_step` and `customer_card`: a separate timestamp
  # header, in MILLISECONDS. Read one as seconds and every delivery lands
  # ~54,000 years in the future.
  SIGNATURE_SURFACES = {
    "unified_v2" => {
      header: V2_SIGNATURE_HEADER, timestamp: IN_SIGNATURE, format: "tv1",
      unit: "seconds", base: "target", also_target: false,
      describe: "the unified v2 signature, sent alongside every surface's legacy header, " \
                "over t.METHOD.path.body"
    },
    "agent_delivery" => {
      header: "x-chatly-signature", timestamp: IN_SIGNATURE, format: "tv1",
      unit: "seconds", base: "body", also_target: false,
      describe: "external-agent push delivery, signed with the bot's signingSecret"
    },
    "event_webhook" => {
      header: "x-livechat-signature", timestamp: IN_SIGNATURE, format: "tv1",
      unit: "seconds", base: "body", also_target: false,
      describe: "event webhook, signed with that subscription's whsec_ secret"
    },
    "ai_tool_call" => {
      header: "x-chatly-signature", timestamp: IN_SIGNATURE, format: "tv1",
      unit: "seconds", base: "target", also_target: false,
      describe: "custom AI tool call, signed with that tool's secret over t.METHOD.path.body"
    },
    "canvas_step" => {
      header: "x-chatly-canvas-signature", timestamp: "x-chatly-canvas-ts", format: "sha256",
      unit: "milliseconds", base: "body", also_target: false,
      describe: "canvas / interactive-step callback, timestamp in MILLISECONDS"
    },
    "customer_card" => {
      header: "x-chatly-signature", timestamp: "x-chatly-timestamp", format: "sha256",
      unit: "milliseconds", base: "body", also_target: false,
      describe: "customer-card fetch, timestamp in MILLISECONDS"
    },
    "workflow_webhook" => {
      header: V2_SIGNATURE_HEADER, timestamp: IN_SIGNATURE, format: "tv1",
      unit: "seconds", base: "body", also_target: true,
      describe: 'workflow "call a webhook" action, replay-bounded v2 header'
    },
    "workflow_webhook_legacy" => {
      header: "x-chatly-signature", timestamp: nil, format: "sha256",
      unit: nil, base: "body_only", also_target: false,
      describe: "workflow action, LEGACY header over the body alone -- no replay protection"
    }
  }.each_value(&:freeze).freeze

  # The surface names, in table order.
  SIGNATURE_SURFACE_NAMES = SIGNATURE_SURFACES.keys.freeze

  # Every `reason` a refusal can carry. Stable: branch on these, never on
  # `message`.
  SIGNATURE_FAILURE_REASONS = %w[
    unknown_surface
    missing_secret
    missing_signature_header
    duplicate_signature_header
    malformed_signature_header
    missing_timestamp
    malformed_timestamp
    timestamp_outside_tolerance
    missing_request_target
    replay_unprotected
    signature_mismatch
  ].freeze

  # What `verify_chatly_signature` returns.
  #
  # On success: `ok? == true`, `surface` (what actually verified --
  # "unified_v2" when a preferred v2 header was used), `timestamp_ms` (Unix
  # MILLISECONDS whatever the surface's unit, nil on
  # `workflow_webhook_legacy`), `base` ("body" / "target" / "body_only") and
  # `secret_index` (the index into the `secret:` you passed that matched --
  # how you learn mid-rotation that the old secret is finally unused).
  #
  # On refusal: `ok? == false`, `surface`, `reason` (one of
  # `SIGNATURE_FAILURE_REASONS`) and a non-empty `message`.
  #
  # A Struct rather than a bare Hash so a typo (`result.reson`) is a
  # NoMethodError in development instead of a silent nil in production.
  SignatureResult = Struct.new(:ok, :surface, :reason, :message, :timestamp_ms, :base, :secret_index,
                               keyword_init: true) do
    def ok?
      ok == true
    end
  end

  # Sugar for `Chatly::Webhooks.verify_chatly_signature`, beside
  # `Chatly.verify_webhook_signature`.
  def self.verify_chatly_signature(**kwargs)
    Webhooks.verify_chatly_signature(**kwargs)
  end

  module Webhooks
    HEX_SHA256 = /\A[0-9a-fA-F]{64}\z/
    DIGITS = /\A\d+\z/
    # JavaScript's Number.MAX_SAFE_INTEGER. See the timestamp check.
    MAX_SAFE_TIMESTAMP = (2**53) - 1
    private_constant :HEX_SHA256, :DIGITS, :MAX_SAFE_TIMESTAMP

    # Verify one signed request from Chatly.
    #
    #   result = Chatly::Webhooks.verify_chatly_signature(
    #     surface: "event_webhook",
    #     body: request.raw_post,
    #     headers: Chatly::Webhooks.rack_headers(request.env),
    #     secret: ENV.fetch("CHATLY_WEBHOOK_SECRET"),
    #     method: request.request_method,
    #     path: request.fullpath
    #   )
    #   unless result.ok?
    #     Rails.logger.warn("chatly: #{result.reason}: #{result.message}")
    #     return head(:bad_request)
    #   end
    #
    # @param surface [String, Symbol] one of `SIGNATURE_SURFACE_NAMES`
    # @param body [String] the EXACT bytes received. The MAC is over the
    #   String's bytes as they are -- a binary (ASCII-8BIT) body is not
    #   transcoded, and a UTF-8 one is its UTF-8 bytes.
    # @param headers [Hash{String=>String, Array<String>}] matched
    #   case-insensitively; every key that matches contributes its values
    # @param secret [String, Array<String>] this surface's secret, or every
    #   secret live on it during a rotation. Empty strings are skipped.
    # @param tolerance_seconds [Numeric] default 300, both directions
    # @param method [String, nil] the HTTP method, needed on target bases
    # @param path [String, nil] pathname + query as received, never the host
    # @param v2 [String, Symbol] "prefer" (default), "require" or "ignore"
    # @param allow_unprotected_replay [Boolean] required to verify
    #   `workflow_webhook_legacy` at all
    # @param now_ms [Integer, nil] Unix MILLISECONDS; for tests
    # @return [Chatly::SignatureResult]
    def self.verify_chatly_signature(surface:, body:, headers:, secret:,
                                     tolerance_seconds: SIGNATURE_TOLERANCE_SECONDS,
                                     method: nil, path: nil, v2: "prefer",
                                     allow_unprotected_replay: false, now_ms: nil)
      input = {
        surface: surface.is_a?(Symbol) ? surface.to_s : surface,
        body: body, headers: headers, secret: secret,
        tolerance_seconds: tolerance_seconds.nil? ? SIGNATURE_TOLERANCE_SECONDS : tolerance_seconds,
        method: method, path: path,
        v2: v2.nil? ? "prefer" : v2.to_s,
        allow_unprotected_replay: allow_unprotected_replay == true,
        now_ms: now_ms
      }
      verify(input)
    rescue StandardError
      # Backstop only -- nothing above is expected to raise. Refusing is the
      # one safe answer to "something went wrong while checking a signature".
      refuse(surface.is_a?(Symbol) ? surface.to_s : surface, "signature_mismatch",
             "The signature could not be checked, so it was refused. Pass the raw body as a " \
             "String, the headers as a Hash, and the secret as a String or an Array of Strings.")
    end

    # Rack exposes request headers as `HTTP_X_CHATLY_SIGNATURE` in `env`, not
    # as `x-chatly-signature`, and `verify_chatly_signature` matches names the
    # way they travel on the wire. This turns an env (Rack's, or Rails'
    # `request.env`) into the Hash it wants.
    #
    # One thing Rack has already done that nothing here can undo: when a
    # header arrives twice, Rack joins the values with ", " into one. The
    # verifier refuses a duplicated signature header, but only when it can
    # SEE two -- through Rack it sees one value with two `v1=` fields. That is
    # still safe (each digest has to verify under your secret), it just reads
    # as one header.
    def self.rack_headers(env)
      return {} unless env.respond_to?(:each_pair)

      out = {}
      env.each_pair do |key, value|
        next unless key.is_a?(String) && value.is_a?(String)

        name = if key.start_with?("HTTP_")
                 key.delete_prefix("HTTP_")
               elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
                 key
               end
        next if name.nil?

        out[name.downcase.tr("_", "-")] = value
      end
      out
    end

    # ── The decision, in the order SPEC / signatures.ts take it ─────────────

    def self.verify(input)
      surface = input[:surface]
      spec = surface.is_a?(String) ? SIGNATURE_SURFACES[surface] : nil
      if spec.nil?
        return refuse(surface, "unknown_surface",
                      "#{surface.to_s.inspect} is not a Chatly signature surface. One of: " \
                      "#{SIGNATURE_SURFACE_NAMES.join(', ')}.")
      end

      secrets = secrets_from(input[:secret])
      if secrets.empty?
        return refuse(surface, "missing_secret",
                      "No secret given for #{surface}. Each surface has its own secret -- " \
                      "#{spec[:describe]}. A secret from another surface will never verify.")
      end

      if surface == "workflow_webhook_legacy" && !input[:allow_unprotected_replay]
        return refuse(surface, "replay_unprotected",
                      "The legacy workflow header signs the body with no timestamp, so a captured " \
                      "request verifies forever and nothing here can bound a replay. The same call " \
                      "also sends #{V2_SIGNATURE_HEADER} -- verify that instead, with surface " \
                      '"workflow_webhook". If you must accept the legacy header, pass ' \
                      "allow_unprotected_replay: true and make the endpoint idempotent.")
      end

      via_v2 = apply_v2_policy(input, spec)
      return via_v2 unless via_v2.nil?

      # ── The digest header ────────────────────────────────────────────────
      values = header_values(input[:headers], spec[:header])
      if values.empty?
        return refuse(surface, "missing_signature_header",
                      "No #{spec[:header]} header. #{capitalise(spec[:describe])} always sends one; " \
                      "if the request carries a differently named signature header, you have the " \
                      "wrong surface.")
      end
      if values.length > 1
        # Two values means something between Chatly and you merged or
        # injected one, and picking either is a guess. Refuse rather than
        # trial-verify both: trial verification would let an attacker who
        # can add a header turn a refusal into "whichever one passes".
        return refuse(surface, "duplicate_signature_header",
                      "#{values.length} #{spec[:header]} headers arrived. Chatly sends exactly one; " \
                      "a proxy merged or added one, and choosing between them would be a guess.")
      end
      unless values.first.is_a?(String)
        return refuse(surface, "malformed_signature_header",
                      "#{spec[:header]} is not a String (got #{values.first.class}).")
      end
      # Parsed as BYTES. Every legitimate value is ASCII, and a header with
      # invalid UTF-8 in it would otherwise raise out of `split` and `match?`
      # -- which the backstop would catch, but as a mismatch rather than as
      # the malformed header it is.
      raw_signature = js_trim(values.first.b)

      raw_timestamp = nil
      marker = nil
      if spec[:format] == "tv1"
        parsed = parse_tv1(raw_signature)
        if parsed.nil?
          return refuse(surface, "malformed_signature_header",
                        "#{spec[:header]} should be \"t=<unix seconds>,v1=<hex>\" on #{surface}; " \
                        "got \"#{preview(raw_signature)}\".")
        end
        digests_hex = parsed[:v1]
        raw_timestamp = parsed[:t]
        marker = parsed[:b]
      else
        unless raw_signature.start_with?("sha256=")
          return refuse(surface, "malformed_signature_header",
                        "#{spec[:header]} should be \"sha256=<hex>\" on #{surface}; got " \
                        "\"#{preview(raw_signature)}\". A \"t=...,v1=...\" value here means you have " \
                        "the wrong surface -- that is the other signature family.")
        end
        digests_hex = [js_trim(raw_signature.delete_prefix("sha256="))]
      end

      digests_hex.each do |hex|
        # Shape-checked BEFORE decoding: `["zz"].pack("H*")` does not fail, it
        # quietly produces garbage bytes, so a malformed digest would
        # otherwise reach the compare and be reported as a mismatch -- which
        # sends the integrator hunting their secret instead of their header.
        next if hex.match?(HEX_SHA256)

        many = digests_hex.length > 1 ? " #{digests_hex.length} v1 values arrived; every one has to be well formed." : ""
        return refuse(surface, "malformed_signature_header",
                      "A digest in #{spec[:header]} is not 64 hex characters (got #{hex.length}).#{many}")
      end

      # ── The timestamp, and its unit ──────────────────────────────────────
      timestamp_ms = nil
      unless spec[:unit].nil?
        if spec[:timestamp].is_a?(String)
          first = header_values(input[:headers], spec[:timestamp]).first
          if first.nil?
            return refuse(surface, "missing_timestamp",
                          "No #{spec[:timestamp]} header. On #{surface} the timestamp travels in its " \
                          "own header and is part of the signed string, so it cannot be reconstructed.")
          end
          unless first.is_a?(String)
            return refuse(surface, "malformed_timestamp",
                          "#{spec[:timestamp]} is not a String (got #{first.class}).")
          end
          raw_timestamp = js_trim(first.b)
        end
        if raw_timestamp.nil? || raw_timestamp.empty?
          return refuse(surface, "missing_timestamp", "No timestamp found for #{surface}.")
        end
        # Strictly digits. `"17abc".to_i` is 17 and `Integer("1_7")` is 17;
        # either would accept a value the sender never wrote, and the MAC is
        # over the RAW text, so the window and the digest would disagree
        # about which timestamp this is.
        unless raw_timestamp.match?(DIGITS)
          return refuse(surface, "malformed_timestamp",
                        "The timestamp on #{surface} is not a run of digits: \"#{preview(raw_timestamp)}\".")
        end
        number = Integer(raw_timestamp, 10)
        # Ruby Integers do not overflow, so "does it fit" has to be a chosen
        # bound, and the one chosen is the reference's: `Number.isSafeInteger`,
        # 2**53 - 1. Every SDK refuses the same values that way -- a Go or
        # Rust SDK whose int64 would overflow at 9.2e18, and this one, which
        # would otherwise call 1e20 "late" and send the integrator to check
        # their clock for a value no clock produces.
        if number > MAX_SAFE_TIMESTAMP
          return refuse(surface, "malformed_timestamp",
                        "The timestamp on #{surface} is too large to be one: \"#{preview(raw_timestamp)}\".")
        end
        timestamp_ms = spec[:unit] == "seconds" ? number * 1000 : number

        tolerance = input[:tolerance_seconds]
        now = input[:now_ms].nil? ? Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) : input[:now_ms]
        # A NaN tolerance would make `drift > NaN` false for EVERY drift and
        # admit any timestamp at all, so it is refused rather than compared.
        # (The Node reference compares it; this is stricter on purpose.)
        unless real_number?(tolerance) && real_number?(now)
          return refuse(surface, "timestamp_outside_tolerance",
                        "tolerance_seconds and now_ms must be numbers (got #{tolerance.class} and " \
                        "#{now.class}), so the freshness window could not be checked.")
        end
        drift_ms = (now - timestamp_ms).abs
        # `>`, not `>=`: exactly the tolerance is inside the window, which is
        # what every SDK and the corpus agree on.
        if drift_ms > tolerance * 1000
          # Both directions refused, and the message says which. A FAR-future
          # timestamp is nearly always the wrong unit, which lands decades or
          # millennia out and would read as "expired" if nothing said so.
          drift_years = drift_ms / (1000.0 * 60 * 60 * 24 * 365)
          hint = if drift_years > 1
                   " That is #{drift_years.round} year(s) out, which is what a wrong UNIT looks " \
                     "like: #{surface} sends #{spec[:unit]}."
                 else
                   ""
                 end
          direction = timestamp_ms > now ? "in the FUTURE" : "in the past"
          return refuse(surface, "timestamp_outside_tolerance",
                        "The timestamp on #{surface} is #{(drift_ms / 1000.0).round}s #{direction}, " \
                        "outside the #{tolerance}s tolerance.#{hint}")
        end
      end

      # ── The base string, and the compare ─────────────────────────────────
      bases = candidate_bases(input, spec, marker)
      return bases if bases.is_a?(SignatureResult)

      if bases.include?("target") && !target?(input)
        return refuse(surface, "missing_request_target",
                      "#{surface} signs <t>.<METHOD>.<path>.<rawBody>, so both method and path are " \
                      "required. path is pathname + query of the request as Chatly rendered it -- " \
                      "not the host, not the scheme.")
      end

      body = input[:body]
      unless body.is_a?(String)
        # Checked here, not first, so that every refusal above still names
        # the real problem. An IO (Rack's `request.body`) is the likely
        # mistake: read it, and rewind it for whoever reads next.
        return refuse(surface, "signature_mismatch",
                      "The body must be the raw request body as a String (got #{body.class}). " \
                      "For a Rack body, pass request.body.read.")
      end
      # Bytes as they are. A binary body is exactly what arrived on the wire;
      # transcoding it to UTF-8 first would change the bytes being MACed. A
      # UTF-8 String's bytes already ARE its UTF-8 encoding.
      body_bytes = body.b
      given = digests_hex.map { |hex| [hex].pack("H*") }

      bases.each do |base|
        prefix = base_prefix(base, raw_timestamp, input)
        secrets.each do |(value, index)|
          expected = OpenSSL::HMAC.digest("SHA256", value, prefix + body_bytes)
          given.each do |candidate|
            # Lengths first inside `secure_compare`: fixed_length_secure_compare
            # RAISES on a length mismatch, and this function must not.
            next unless secure_compare(expected, candidate)

            return SignatureResult.new(ok: true, surface: surface, timestamp_ms: timestamp_ms,
                                       base: base, secret_index: index).freeze
          end
        end
      end

      many = secrets.length > 1 ? " None of the #{secrets.length} secrets matched." : ""
      refuse(surface, "signature_mismatch",
             "The digest does not match for #{surface}. The three usual causes, in order: a " \
             "re-serialised body (pass the RAW bytes, not JSON of the parsed object), the secret " \
             "from a different surface, or the wrong surface -- #{spec[:describe]}.#{many}")
    end
    private_class_method :verify

    # The v2 decision, taken before anything is parsed. Returns a result when
    # it has answered the whole question (delegated to `unified_v2`, or
    # refused) and nil when verification continues on the surface asked for.
    def self.apply_v2_policy(input, spec)
      surface = input[:surface]
      policy = input[:v2]
      return nil if policy == "ignore" || surface == "unified_v2"
      # A surface whose OWN header is the v2 header handles both bases in its
      # candidate list instead; there is nothing to delegate to.
      return nil if spec[:header] == V2_SIGNATURE_HEADER

      present = !header_values(input[:headers], V2_SIGNATURE_HEADER).empty?
      if policy == "require" && !present
        return refuse(surface, "missing_signature_header",
                      "v2: \"require\" was asked for and this request carries no " \
                      "#{V2_SIGNATURE_HEADER} header. #{spec[:header]} alone means the sender has " \
                      "not moved to the unified construction yet -- use the default v2: \"prefer\" " \
                      "until it has.")
      end
      return nil unless present

      unless target?(input)
        if policy == "require"
          return refuse(surface, "missing_request_target",
                        "The unified #{V2_SIGNATURE_HEADER} signs <t>.<METHOD>.<path>.<rawBody>, so " \
                        "both method and path are required to verify it. path is pathname + query " \
                        "of the request as it arrived -- not the host, not the scheme.")
        end
        # "prefer" with no target: the legacy header is still sent beside
        # v2, so fall through rather than refuse a request the caller CAN
        # verify.
        return nil
      end

      result = verify(input.merge(surface: "unified_v2", v2: "ignore"))
      return result if result.ok?

      refuse("unified_v2", result.reason,
             "#{result.message} (This request carried #{V2_SIGNATURE_HEADER}, so it was verified " \
             "as the unified v2 construction rather than as #{surface}. Pass v2: \"ignore\" to " \
             "verify #{spec[:header]} instead.)")
    end
    private_class_method :apply_v2_policy

    # Which strings the MAC may have been taken over, most specific first --
    # or a refusal when the value's `b=` marker rules every candidate out.
    #
    # The marker (`b=t` target, `b=b` body) is read ONLY off the v2 header,
    # and it only ever NARROWS what the surface and the policy allow: anyone
    # on the wire can write a marker, so it must never widen the set. An
    # absent or unrecognised marker changes nothing, because every v2 value
    # minted before the marker existed has none. What it buys is the error:
    # a receiver passing no method/path gets `missing_request_target` rather
    # than a `signature_mismatch` that sends them hunting their secret.
    def self.candidate_bases(input, spec, marker)
      surface = input[:surface]
      policy = input[:v2]
      from_v2 = spec[:header] == V2_SIGNATURE_HEADER
      if from_v2 && marker == "b" && (spec[:base] == "target" || policy == "require")
        tail = if surface == "unified_v2"
                 'unified_v2 accepts only b=t. Verify it with surface "workflow_webhook", which accepts both.'
               else
                 'v2: "require" accepts only the unified base (b=t).'
               end
        return refuse(surface, "signature_mismatch",
                      "This #{V2_SIGNATURE_HEADER} is marked b=b: it was signed over <t>.<rawBody>, " \
                      "the workflow action's pre-unified base. #{tail}")
      end
      return [spec[:base]] if !spec[:also_target] || policy == "ignore"
      return ["target"] if marker == "t"
      return [spec[:base]] if marker == "b" || !target?(input)

      # "require" on this surface means the unified base and nothing else.
      policy == "require" ? ["target"] : ["target", spec[:base]]
    end
    private_class_method :candidate_bases

    # Built as BINARY so a path in a non-UTF-8 encoding cannot raise
    # Encoding::CompatibilityError on the `+` with the body. Method and path
    # are text, so they are taken as their UTF-8 encoding (what the sender
    # signed); the timestamp is the RAW header text, never re-rendered, so a
    # sender that wrote `t=0700000000` is verified over that string.
    def self.base_prefix(base, raw_timestamp, input)
      return "".b if base == "body_only"

      t = raw_timestamp.to_s
      return "#{t}.".b if base == "body"

      "#{t}.".b + utf8_bytes(input[:method].to_s.upcase) + ".".b + utf8_bytes(input[:path].to_s) + ".".b
    end
    private_class_method :base_prefix
  end
end
