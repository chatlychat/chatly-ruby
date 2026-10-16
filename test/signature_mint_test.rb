# frozen_string_literal: true

require_relative "test_helper"

# `Chatly.sign_chatly_v2` -- against the reference's bytes, and round-tripped.
#
# Three claims, and only the first two are worth much on their own:
#
#   1. The base string is the documented one. Pinned as a literal, computed
#      nowhere in this file, because a test that derives the expected string
#      the way the code does agrees with the code's mistakes. The frozen value
#      is the one `packages/shared/src/webhook-signature/v2.spec.ts` carries.
#   2. What this mints verifies through this gem's OWN
#      `verify_chatly_signature`, and a one-byte change to the body, path,
#      method, secret or timestamp makes it stop. Round-tripping alone proves
#      only that the two halves of this gem agree -- which they would if both
#      were wrong the same way -- so (1) is what anchors it.
#   3. The workflow action's DUAL-DIGEST value, `t=<T>,v1=<target>,v1=<body>`
#      with NO marker, verifies both ways. That is the shape production sends
#      today (`WORKFLOW_WEBHOOK_V2_PHASE = "dual"`), it is in the published
#      docs, and the cross-SDK corpus has no vector for it -- so without this
#      file nothing here covers the one wire value a workflow-webhook
#      integrator actually receives.
class SignatureMintTest < ChatlyTest
  SECRET = "whsec_mint_secret"
  BODY = '{"id":"evt_1","type":"message.created"}'
  T = 1_760_000_000
  NOW_MS = 1_760_000_000_000
  METHOD = "POST"
  PATH = "/hooks/chatly?tenant=42"

  # The `v1=` field out of a minted value.
  #
  # The producer does exactly this to assemble the dual-digest value
  # (`digestOf` in `apps/worker/src/handlers/action-handlers/fire-webhook.ts`),
  # so the dual case below is built the way the bytes on the wire are.
  def digest_of(value)
    field = value.split(",").find { |part| part.start_with?("v1=") }

    refute_nil field, "no v1 field in #{value.inspect}"
    field.delete_prefix("v1=")
  end

  def mint(**overrides)
    Chatly.sign_chatly_v2(**{
      base: "target", secret: SECRET, timestamp_seconds: T,
      body: BODY, method: METHOD, path: PATH
    }.merge(overrides))
  end

  def verify(header, **overrides)
    Chatly.verify_chatly_signature(**{
      surface: "unified_v2", body: BODY, secret: SECRET, method: METHOD, path: PATH,
      headers: { "x-chatly-signature-v2" => header }, now_ms: NOW_MS
    }.merge(overrides))
  end

  # -- the base string ------------------------------------------------------

  def test_the_target_base_is_t_method_path_body
    assert_equal '1760000000.POST./hooks/chatly?tenant=42.{"id":"evt_1","type":"message.created"}',
                 Chatly.chatly_v2_base_string(base: "target", timestamp_seconds: T, body: BODY,
                                              method: METHOD, path: PATH)
  end

  def test_the_body_base_is_t_body
    assert_equal '1760000000.{"id":"evt_1","type":"message.created"}',
                 Chatly.chatly_v2_base_string(base: "body", timestamp_seconds: T, body: BODY)
  end

  def test_the_method_is_upper_cased_and_the_path_is_not
    # The verifier upper-cases the method and leaves the path alone, so a mint
    # that normalised the path would produce a value nothing verifies.
    assert_equal "1760000000.GET./Mixed/Case?A=1.",
                 Chatly.chatly_v2_base_string(base: "target", timestamp_seconds: T, body: "",
                                              method: "get", path: "/Mixed/Case?A=1")
  end

  def test_the_base_string_is_binary_and_keeps_a_bodys_bytes
    # Not every body is valid UTF-8 text and the MAC is over bytes. The
    # verifier takes `body.b`, so this must too -- transcoding would change
    # what is MACed.
    base = Chatly.chatly_v2_base_string(base: "body", timestamp_seconds: T,
                                        body: "\xFF\xFE".b)

    assert_equal Encoding::BINARY, base.encoding
    assert_equal "1760000000.\xFF\xFE".b, base
  end

  def test_the_frozen_vector_matches_the_shared_producer
    # The frozen vector from `packages/shared/src/webhook-signature/v2.spec.ts`
    # ("matches a frozen vector, byte for byte"), minted here. Two independent
    # implementations of one construction (ADR 0056) held against the same
    # bytes -- field order, separators, digest case and marker letter
    # included, which is why it is a whole value and not just a digest.
    assert_equal "t=1700000000,v1=a22f16be6cc2f88da16b175e5057406cbe820e116b9e74375a0020f1c94f5975,b=t",
                 Chatly.sign_chatly_v2(base: "target", secret: "whsec_frozen",
                                       timestamp_seconds: 1_700_000_000,
                                       method: "POST", path: "/x", body: '{"a":1}')
  end

  # -- the marker -----------------------------------------------------------

  def test_the_marker_says_which_base
    target = mint
    body = mint(base: "body", method: nil, path: nil)

    assert target.end_with?(",b=t"), target
    assert body.end_with?(",b=b"), body
    # Different bases must be different digests, or the marker would be the
    # only thing telling them apart and `b=` is free for anyone to write.
    refute_equal digest_of(target), digest_of(body)
  end

  def test_there_is_no_default_base
    assert_raises(ArgumentError) do
      Chatly.sign_chatly_v2(secret: SECRET, timestamp_seconds: T, body: BODY)
    end
    assert_raises(ArgumentError) do
      Chatly.sign_chatly_v2(base: "unified", secret: SECRET, timestamp_seconds: T, body: BODY)
    end
  end

  # -- refusals, rather than a value nothing can verify ---------------------

  def test_the_target_base_requires_a_method_and_a_path
    [{}, { method: METHOD }, { path: PATH }, { method: "", path: "" }].each do |partial|
      assert_raises(ArgumentError, partial.inspect) do
        Chatly.sign_chatly_v2(base: "target", secret: SECRET, timestamp_seconds: T, body: BODY,
                              **partial)
      end
    end
  end

  def test_an_empty_secret_is_refused
    # An empty String is a valid HMAC key, which is the problem: the likeliest
    # cause is an environment variable that never got set.
    assert_raises(ArgumentError) do
      Chatly.sign_chatly_v2(base: "body", secret: "", timestamp_seconds: T, body: BODY)
    end
  end

  def test_a_non_integer_timestamp_is_refused
    # `1_760_000_000.0.to_s` is "1760000000.0" and the verifier's `t` must be a
    # run of digits, so a Float would sign text nothing can reproduce.
    [1_760_000_000.0, "1760000000", nil, Time.at(T)].each do |ts|
      assert_raises(ArgumentError, ts.inspect) do
        Chatly.sign_chatly_v2(base: "body", secret: SECRET, timestamp_seconds: ts, body: BODY)
      end
    end
    assert_raises(ArgumentError) do
      Chatly.sign_chatly_v2(base: "body", secret: SECRET, timestamp_seconds: -1, body: BODY)
    end
  end

  def test_a_parsed_body_is_refused
    assert_raises(ArgumentError) do
      Chatly.sign_chatly_v2(base: "body", secret: SECRET, timestamp_seconds: T,
                            body: { "id" => "evt_1" })
    end
  end

  # -- round trip -----------------------------------------------------------

  def test_a_minted_target_value_verifies_as_unified_v2
    result = verify(mint)

    assert result.ok?, result.message
    assert_equal "target", result.base
    assert_equal NOW_MS, result.timestamp_ms
  end

  def test_a_minted_body_value_verifies_as_workflow_webhook
    result = verify(mint(base: "body", method: nil, path: nil),
                    surface: "workflow_webhook", method: nil, path: nil)

    assert result.ok?, result.message
    assert_equal "body", result.base
  end

  def test_one_changed_byte_stops_it_verifying
    # Each row changes exactly ONE thing between the mint and the verify.
    # Without these, "it verifies" could be an unconditional yes.
    header = mint

    assert_equal "signature_mismatch", verify(header, path: "#{PATH}0").reason, "path"
    assert_equal "signature_mismatch", verify(header, method: "PUT").reason, "method"
    assert_equal "signature_mismatch", verify(header, body: "#{BODY} ").reason, "body"
    assert_equal "signature_mismatch", verify(header, secret: "whsec_other").reason, "secret"
    assert_equal "timestamp_outside_tolerance",
                 verify(mint(timestamp_seconds: T - 301)).reason, "a t 301s old"
  end

  def test_a_forged_marker_cannot_move_the_base
    # `b=` is something anyone on the wire can write, so re-labelling a body
    # digest as the target base must not make it verify.
    body_value = mint(base: "body", method: nil, path: nil)
    forged = "#{body_value.delete_suffix(',b=b')},b=t"

    assert_equal "signature_mismatch", verify(forged).reason
  end

  def test_a_non_utf8_body_round_trips
    # The mint takes a body's bytes as they are and so does the verifier. If
    # either transcoded, this is the case that would diverge.
    raw = "\xC3\x28".b
    header = Chatly.sign_chatly_v2(base: "body", secret: SECRET, timestamp_seconds: T, body: raw)
    result = verify(header, surface: "workflow_webhook", body: raw, method: nil, path: nil)

    assert result.ok?, result.message
  end

  # -- the dual-digest value production sends today -------------------------

  # `WORKFLOW_WEBHOOK_V2_PHASE = "dual"` in
  # `apps/worker/src/handlers/action-handlers/fire-webhook.ts`, documented on
  # `/docs/api-external-agents`. The cross-SDK corpus has no vector for it.
  #
  # Unified first, body last, and NO marker -- the order and the absence are
  # both load-bearing. A `b=b` would make `unified_v2` refuse the value
  # outright; a `b=t` would send a verifier that keeps only the last `v1` to
  # compare the target base against the body digest.
  def dual
    target = mint
    body = mint(base: "body", method: nil, path: nil)
    "t=#{T},v1=#{digest_of(target)},v1=#{digest_of(body)}"
  end

  def test_the_dual_shape_is_two_v1_fields_and_no_marker
    value = dual

    assert_equal 2, value.scan(",v1=").length, value
    refute_includes value, "b="
  end

  def test_the_dual_value_verifies_as_unified_v2_with_a_target
    result = verify(dual)

    assert result.ok?, result.message
    assert_equal "target", result.base
  end

  def test_the_dual_value_verifies_as_workflow_webhook_either_way
    # With a target it takes the unified digest; without one it falls to the
    # body digest, which is the receiver that has not migrated. Both must
    # pass, or the migration this shape exists to enable is broken in one
    # direction.
    with_target = verify(dual, surface: "workflow_webhook")

    assert with_target.ok?, with_target.message
    assert_equal "target", with_target.base

    without = verify(dual, surface: "workflow_webhook", method: nil, path: nil)

    assert without.ok?, without.message
    assert_equal "body", without.base
  end

  def test_a_tampered_body_fails_both_dual_digests
    # Two valid digests must not mean two chances at a forgery.
    [{}, { method: nil, path: nil }].each do |target|
      result = verify(dual, surface: "workflow_webhook", body: "#{BODY}x", **target)

      assert_equal "signature_mismatch", result.reason, target.inspect
    end
  end

  # -- the public surface ---------------------------------------------------

  def test_the_module_functions_and_the_webhooks_namespace_are_the_same
    assert_equal %w[target body], Chatly::V2_MINT_BASES
    assert_equal mint, Chatly::Webhooks.sign_chatly_v2(
      base: "target", secret: SECRET, timestamp_seconds: T, body: BODY,
      method: METHOD, path: PATH
    )
    assert_equal Chatly.chatly_v2_base_string(base: "body", timestamp_seconds: T, body: BODY),
                 Chatly::Webhooks.chatly_v2_base_string(base: "body", timestamp_seconds: T,
                                                        body: BODY)
  end
end
