# frozen_string_literal: true

require_relative "test_helper"
require "openssl"
require "stringio"

# `Chatly::Webhooks.verify_chatly_signature` against the cross-SDK corpus.
#
# The corpus is generated from the Node reference and copied byte-for-byte
# into every SDK; sdk-node's own spec fails if any copy drifts, so this file
# never edits it. It is loaded relative to THIS file because in the public
# mirror the SDK directory is the repository root and there is no
# `../sdk-node` to reach for.
#
# Why a corpus and not just hand-written tests: each SDK's hand-written tests
# agree with that SDK's reading of the spec, which is exactly the thing that
# drifts. A shared list of inputs and answers is the only test that can tell
# two implementations apart.
class SignatureCorpusTest < ChatlyTest
  CORPUS_PATH = File.expand_path("fixtures/signature_vectors.json", __dir__)
  CORPUS = JSON.parse(File.read(CORPUS_PATH))
  VECTORS = CORPUS.fetch("vectors")

  # A floor, not an exact count: the corpus is meant to grow. What it guards
  # is a loader that silently finds nothing -- zero vectors is a green run.
  # 59 -> 61 on 2026-10-16: the corpus holds 61, so this was blind to the two
  # newest vectors. Go, Rust, Java and .NET already floored at the count.
  MIN_VECTORS = 61

  # Corpus input keys are camelCase (the Node reference wrote them); this is
  # the one place that maps them onto Ruby keywords. An unknown key fails the
  # test rather than being dropped, so a new corpus field cannot be ignored
  # here and pass by omission.
  INPUT_KEYS = {
    "surface" => :surface, "body" => :body, "headers" => :headers, "secret" => :secret,
    "method" => :method, "path" => :path, "v2" => :v2,
    "allowUnprotectedReplay" => :allow_unprotected_replay,
    "toleranceSeconds" => :tolerance_seconds, "nowMs" => :now_ms
  }.freeze

  def test_the_corpus_loaded_at_least_the_floor
    assert_equal 1, CORPUS["version"]
    assert_operator VECTORS.length, :>=, MIN_VECTORS,
                    "the corpus loaded #{VECTORS.length} vectors -- the loader has stopped finding them"
  end

  # One assertion message per vector, all collected, so a regression reports
  # every vector it broke rather than the first.
  def test_every_vector
    failures = VECTORS.filter_map { |vector| check(vector) }

    assert_empty failures, "#{failures.length} vector(s) failed:\n  #{failures.join("\n  ")}"
  end

  # Every reason this SDK can return has at least one vector. If the corpus
  # ever stops covering one -- or this SDK grows a reason the others do not
  # have -- this says so.
  def test_the_corpus_covers_every_reason
    seen = VECTORS.map { |v| v.dig("expect", "reason") }.compact.uniq

    assert_empty Chatly::SIGNATURE_FAILURE_REASONS - seen
  end

  private

  def check(vector)
    name = vector.fetch("name")
    unknown = vector.fetch("input").keys - INPUT_KEYS.keys
    return "#{name}: unknown input key(s) #{unknown.inspect}" unless unknown.empty?

    kwargs = vector.fetch("input").to_h { |key, value| [INPUT_KEYS.fetch(key), value] }
    result = Chatly::Webhooks.verify_chatly_signature(**kwargs)
    expect = vector.fetch("expect")

    problems = []
    problems << "ok #{result.ok?.inspect} != #{expect['ok'].inspect}" unless result.ok? == expect["ok"]
    problems << "surface #{result.surface.inspect} != #{expect['surface'].inspect}" unless result.surface == expect["surface"]
    if expect["ok"]
      { "base" => :base, "secretIndex" => :secret_index, "timestampMs" => :timestamp_ms }.each do |key, attr|
        next if result.public_send(attr) == expect.fetch(key)

        problems << "#{attr} #{result.public_send(attr).inspect} != #{expect.fetch(key).inspect}"
      end
      problems << "reason should be nil, is #{result.reason.inspect}" unless result.reason.nil?
    else
      problems << "reason #{result.reason.inspect} != #{expect['reason'].inspect}" unless result.reason == expect.fetch("reason")
      problems << "empty message on a refusal" unless result.message.is_a?(String) && !result.message.strip.empty?
    end
    # Anything that came out (stripped of `ok`) has to be named in `expect`,
    # so a stray field -- say, a secret_index on a refusal -- is a failure.
    extra = result.to_h.compact.keys.map(&:to_s) - %w[ok surface reason message base secret_index timestamp_ms]
    problems << "unexpected fields #{extra.inspect}" unless extra.empty?
    problems.empty? ? nil : "#{name}: #{problems.join('; ')} (#{result.message})"
  end
end

# What the corpus cannot say, because it is JSON: Ruby-specific inputs
# (binary Strings, Symbols, IO bodies) and garbage of every type.
class SignatureRubyTest < ChatlyTest
  SECRET = "whsec_ruby_secret"
  NOW_MS = 1_760_000_000_000
  T = (NOW_MS / 1000).to_s

  def sign(base_string, secret = SECRET)
    OpenSSL::HMAC.hexdigest("SHA256", secret, base_string)
  end

  def verify(**overrides)
    Chatly::Webhooks.verify_chatly_signature(
      **{ surface: "event_webhook", body: "{}", headers: {}, secret: SECRET, now_ms: NOW_MS }.merge(overrides)
    )
  end

  # A binary body is MACed over its bytes exactly; transcoding it (or
  # rejecting the invalid UTF-8 in it) would break every non-UTF-8 payload.
  def test_a_binary_body_is_used_as_is
    body = "\xFF\x00\xC3(".b
    header = "t=#{T},v1=#{sign("#{T}.".b + body)}"

    assert_predicate verify(body: body, headers: { "x-livechat-signature" => header }), :ok?
  end

  def test_a_utf8_body_is_its_utf8_bytes
    body = +"café \u{1F600}"
    header = "t=#{T},v1=#{sign("#{T}.#{body}".b)}"

    assert_predicate verify(body: body, headers: { "x-livechat-signature" => header }), :ok?
    # The same characters as a different encoding are DIFFERENT bytes, and
    # the reference MACs bytes -- so a Latin-1 copy must not verify.
    latin1 = "café".encode("ISO-8859-1")
    utf8_header = "t=#{T},v1=#{sign("#{T}.café".b)}"

    refute_predicate verify(body: latin1, headers: { "x-livechat-signature" => utf8_header }), :ok?
  end

  def test_a_symbol_surface_and_symbol_header_keys_work
    header = "t=#{T},v1=#{sign("#{T}.{}")}"
    result = verify(surface: :event_webhook, headers: { "X-LiveChat-Signature": header })

    assert_predicate result, :ok?
    assert_equal "event_webhook", result.surface
  end

  def test_a_non_utf8_path_does_not_raise
    path = "/caf\xE9".b
    header = "t=#{T},v1=#{sign("#{T}.POST.".b + path + ".{}".b)}"
    result = verify(surface: "ai_tool_call", method: "post", path: path,
                    headers: { "x-chatly-signature" => header })

    assert_predicate result, :ok?
  end

  def test_rack_headers_turns_an_env_into_wire_names
    env = { "HTTP_X_CHATLY_SIGNATURE_V2" => "a", "CONTENT_TYPE" => "application/json",
            "REQUEST_METHOD" => "POST", "rack.input" => Object.new }

    assert_equal({ "x-chatly-signature-v2" => "a", "content-type" => "application/json" },
                 Chatly::Webhooks.rack_headers(env))
    assert_equal({}, Chatly::Webhooks.rack_headers(nil))
  end

  def test_an_io_body_is_refused_with_a_message_that_says_read_it
    header = "t=#{T},v1=#{sign("#{T}.{}")}"
    result = verify(body: StringIO.new("{}"), headers: { "x-livechat-signature" => header })

    refute_predicate result, :ok?
    assert_equal "signature_mismatch", result.reason
    assert_match(/request\.body\.read/, result.message)
  end

  def test_the_result_is_frozen_and_the_constants_are_exported
    assert_predicate verify, :frozen?
    assert_equal 300, Chatly::SIGNATURE_TOLERANCE_SECONDS
    assert_equal "x-chatly-signature-v2", Chatly::V2_SIGNATURE_HEADER
    assert_equal 8, Chatly::SIGNATURE_SURFACE_NAMES.length
    assert_equal 11, Chatly::SIGNATURE_FAILURE_REASONS.length
    assert_same Chatly::Webhooks.method(:verify_chatly_signature).owner,
                Chatly::Webhooks.singleton_class
  end

  def test_the_top_level_sugar_delegates
    header = "t=#{T},v1=#{sign("#{T}.{}")}"

    assert_predicate Chatly.verify_chatly_signature(surface: "event_webhook", body: "{}", secret: SECRET,
                                                    headers: { "x-livechat-signature" => header },
                                                    now_ms: NOW_MS), :ok?
  end

  # The old boolean verifier is untouched: same construction, same answer.
  def test_verify_webhook_signature_is_unchanged
    header = "t=#{T},v1=#{sign("#{T}.{}")}"

    assert Chatly.verify_webhook_signature("{}", header, SECRET, now: NOW_MS / 1000)
  end

  # ── Never raises ─────────────────────────────────────────────────────────

  BACKSTOP = /could not be checked, so it was refused/

  GARBAGE = [nil, 42, 4.2, :sym, [], {}, [nil], [1, 2], { "a" => 1 }, Object.new, "", "\xFF".b,
             "\xFF\xFE".dup.force_encoding("UTF-8"), Float::NAN, true].freeze

  def test_garbage_in_every_slot_comes_back_refused_and_never_raises
    good_header = { "x-livechat-signature" => "t=#{T},v1=#{sign("#{T}.{}")}" }
    slots = %i[surface body headers secret method path v2 now_ms tolerance_seconds allow_unprotected_replay]
    slots.each do |slot|
      GARBAGE.each do |junk|
        result = verify(headers: good_header, slot => junk)

        assert_kind_of Chatly::SignatureResult, result, "#{slot}=#{junk.inspect}"
        next if result.ok?

        # Some junk is harmless in some slots (a garbage `method` on a body
        # surface, a garbage `v2` that reads as "prefer"); what matters is
        # that nothing raised and that every refusal is well formed.
        assert_includes Chatly::SIGNATURE_FAILURE_REASONS, result.reason, "#{slot}=#{junk.inspect}"
        refute_empty result.message.to_s, "#{slot}=#{junk.inspect}"
        # And none of it reached the rescue backstop: every refusal here is
        # a decision with a real reason, not "something raised".
        refute_match BACKSTOP, result.message, "#{slot}=#{junk.inspect} hit the backstop"
      end
    end
  end

  def test_garbage_where_it_matters_is_a_refusal
    good = "t=#{T},v1=#{sign("#{T}.{}")}"

    [nil, 42, {}, [], Object.new].each do |junk|
      refute_predicate verify(body: junk, headers: { "x-livechat-signature" => good }), :ok?, "body=#{junk.inspect}"
      refute_predicate verify(secret: junk, headers: { "x-livechat-signature" => good }), :ok?, "secret=#{junk.inspect}"
      refute_predicate verify(headers: junk), :ok?, "headers=#{junk.inspect}"
      refute_predicate verify(headers: { "x-livechat-signature" => junk }), :ok?, "header value=#{junk.inspect}"
      refute_predicate verify(surface: junk), :ok?, "surface=#{junk.inspect}"
    end
  end

  def test_garbage_header_values_never_raise
    values = ["", ",,,", "=", "t=", "v1=", "t=1,v1=", "sha256=", "t=#{T},v1=#{'z' * 64}",
              "t=#{'9' * 400},v1=#{'a' * 64}", "t=-1,v1=#{'a' * 64}", "\xFF\xFE".b,
              "t=\xFF,v1=a".dup.force_encoding("UTF-8"), "t=#{T},v1=#{'a' * 64}," * 1000]
    Chatly::SIGNATURE_SURFACE_NAMES.each do |surface|
      values.each do |value|
        headers = Chatly::SIGNATURE_SURFACES[surface].values_at(:header).to_h { |h| [h, value] }
        headers["x-chatly-canvas-ts"] = value
        headers["x-chatly-timestamp"] = value
        result = verify(surface: surface, headers: headers, method: "POST", path: "/x",
                        allow_unprotected_replay: true)

        refute_predicate result, :ok?, "#{surface} #{value.inspect[0, 40]}"
        refute_empty result.message.to_s
        refute_match BACKSTOP, result.message, "#{surface} #{value.inspect[0, 40]} hit the backstop"
      end
    end
  end

  # A timestamp too large for a double is malformed, as in the reference --
  # not "late", which would send the integrator to check their clock.
  def test_an_absurd_timestamp_is_malformed
    result = verify(headers: { "x-livechat-signature" => "t=#{'9' * 400},v1=#{'a' * 64}" })

    assert_equal "malformed_timestamp", result.reason
  end

  # Ruby's `strip` removes a trailing NUL; JavaScript's `trim` does not, so
  # Node refuses this digest as malformed and `strip` would have accepted it.
  # One answer across all eight SDKs, and a header with a NUL in it is not
  # something any Chatly sender emits.
  def test_a_trailing_nul_is_not_trimmed_away
    body = "{}"
    t = "1760000000"
    digest = OpenSSL::HMAC.hexdigest("SHA256", "s", "#{t}.#{body}")
    result = Chatly::Webhooks.verify_chatly_signature(
      surface: "event_webhook", body: body, secret: "s", now_ms: 1_760_000_000_000,
      headers: { "x-livechat-signature" => "t=#{t},v1=#{digest}\0" }
    )
    refute result.ok?
    assert_equal "malformed_signature_header", result.reason
  end

end
