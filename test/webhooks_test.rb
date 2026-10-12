# frozen_string_literal: true

require_relative "test_helper"
require "openssl"

# CONTRACT.md §10.7 and §10.9 -- webhook signature verification.
#
# "An earlier Node implementation HMAC'd the body alone and so rejected 100%
# of genuine deliveries. There is a test for the exact construction; keep
# it."
class WebhooksTest < ChatlyTest
  SECRET = "whsec_test_secret"
  BODY = '{"id":"evt_1","type":"conversation.created"}'
  NOW = 1_762_000_000

  def header_for(body, timestamp, secret = SECRET)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
    "t=#{timestamp},v1=#{digest}"
  end

  def verify(body, header, secret = SECRET, tolerance = 300, now: NOW)
    Chatly.verify_webhook_signature(body, header, secret, tolerance, now: now)
  end

  def test_accepts_a_genuine_signature_over_timestamp_dot_body
    assert verify(BODY, header_for(BODY, NOW))
  end

  # The exact bug: HMAC over the body ALONE. It must be rejected, because a
  # verifier that accepts it is a verifier with no replay window at all.
  def test_rejects_a_digest_taken_over_the_body_alone
    body_only = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)

    refute verify(BODY, "t=#{NOW},v1=#{body_only}")
  end

  def test_rejects_a_digest_over_the_timestamp_alone
    ts_only = OpenSSL::HMAC.hexdigest("SHA256", SECRET, NOW.to_s)

    refute verify(BODY, "t=#{NOW},v1=#{ts_only}")
  end

  # The producer joins with a literal ".", so a verifier that concatenated
  # without it would also reject every genuine delivery.
  def test_rejects_a_digest_over_timestamp_and_body_without_the_separator
    joined = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{NOW}#{BODY}")

    refute verify(BODY, "t=#{NOW},v1=#{joined}")
  end

  def test_rejects_a_stale_timestamp
    stale = NOW - 301

    refute verify(BODY, header_for(BODY, stale))
    assert verify(BODY, header_for(BODY, NOW - 299))
  end

  # Clock skew runs both ways: a producer a few seconds ahead of the
  # consumer is normal, a delivery from the future by an hour is not.
  def test_rejects_a_timestamp_too_far_in_the_future
    refute verify(BODY, header_for(BODY, NOW + 301))
    assert verify(BODY, header_for(BODY, NOW + 10))
  end

  def test_tolerance_is_configurable_and_infinity_admits_an_archived_delivery
    old = NOW - 100_000

    refute verify(BODY, header_for(BODY, old))
    assert verify(BODY, header_for(BODY, old), SECRET, 200_000)
    assert verify(BODY, header_for(BODY, old), SECRET, Float::INFINITY)
  end

  def test_rejects_the_wrong_secret
    refute verify(BODY, header_for(BODY, NOW, "whsec_someone_elses"))
  end

  def test_rejects_a_modified_body
    refute verify('{"id":"evt_2"}', header_for(BODY, NOW))
  end

  # Re-serialising parsed JSON reorders keys and changes whitespace. This is
  # that mistake, made concrete: same data, different bytes, no match. It is
  # why the function takes bytes and never an object.
  def test_a_reserialised_body_does_not_verify
    header = header_for('{"a":1,"b":2}', NOW)

    refute verify('{"b":2,"a":1}', header)
    refute verify('{ "a": 1, "b": 2 }', header)
  end

  # Every malformed input must return false and NOT raise: "a verifier that
  # throws is an accepted webhook in a handler that forgot to catch."
  def test_malformed_headers_return_false_and_never_raise
    [
      "",
      "garbage",
      "t=,v1=",
      "v1=abc",                                  # no t
      "t=#{NOW}",                                # no v1
      "t=not-a-number,v1=abc",
      "t=#{NOW}.5,v1=abc",                       # not an integer
      "t=17abc,v1=abc",                          # a lenient parse would read 17
      "t=#{NOW},v1=zzzz",                        # not hex
      "t=#{NOW},v1=#{'a' * 63}",                 # one char short of a digest
      "t=#{NOW},v1=#{'a' * 65}",
      "=#{NOW},v1=abc",                          # empty key
      ",,,",
      "t#{NOW}v1abc"
    ].each do |header|
      result = nil
      begin
        result = verify(BODY, header)
      rescue StandardError => e
        flunk "verify raised #{e.class} on #{header.inspect}; it must return false"
      end
      assert_equal false, result, "#{header.inspect} must not verify"
    end
  end

  # The test that distinguishes a STRICT `t` parse from a lenient one, and
  # the reason the strict one is there.
  #
  # Every other malformed-`t` case in the list above is rejected by the
  # tolerance check or the digest anyway, so the `\A\d+\z` guard looks
  # redundant -- verified by mutation: deleting it failed nothing until this
  # test existed. What it actually buys is that the timestamp has ONE
  # canonical spelling on the wire. `"+1762000000".to_i` is 1762000000, so a
  # lenient parse accepts a header the producer could never have written and
  # then verifies a digest computed over that spelling.
  def test_a_non_canonical_timestamp_spelling_is_rejected_even_with_a_matching_digest
    digest = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "+#{NOW}.#{BODY}")

    refute verify(BODY, "t=+#{NOW},v1=#{digest}")
  end

  def test_non_string_inputs_return_false_rather_than_raising
    refute verify(nil, header_for(BODY, NOW))
    refute verify({ "id" => "evt_1" }, header_for(BODY, NOW))
    refute verify(BODY, nil)
    refute verify(BODY, header_for(BODY, NOW), "")
    refute verify(BODY, header_for(BODY, NOW), nil)
  end

  def test_extra_and_unknown_header_fields_are_tolerated
    genuine = header_for(BODY, NOW)

    assert verify(BODY, "#{genuine},v0=deadbeef")
    assert verify(BODY, " t=#{NOW} , v1=#{genuine.split('v1=').last} ")
  end

  # A captured header with an attacker's digest appended must not have that
  # second value preferred. Neither value verifies under our secret, but
  # first-wins keeps the behaviour obvious.
  def test_the_first_v1_wins
    genuine = header_for(BODY, NOW)
    forged = OpenSSL::HMAC.hexdigest("SHA256", "whsec_attacker", "#{NOW}.#{BODY}")

    assert verify(BODY, "#{genuine},v1=#{forged}")
    refute verify(BODY, "t=#{NOW},v1=#{forged},v1=#{genuine.split('v1=').last}")
  end

  def test_an_uppercase_hex_digest_still_verifies
    genuine = header_for(BODY, NOW)
    upper = genuine.sub(/v1=(.+)/) { "v1=#{Regexp.last_match(1).upcase}" }

    assert verify(BODY, upper)
  end

  def test_the_default_tolerance_is_five_minutes
    assert_equal 300, Chatly::WEBHOOK_SIGNATURE_TOLERANCE_SECONDS
  end

  def test_tolerance_and_now_default_to_real_values
    now = Time.now.to_i

    assert Chatly.verify_webhook_signature(BODY, header_for(BODY, now), SECRET)
    refute Chatly.verify_webhook_signature(BODY, header_for(BODY, now - 400), SECRET)
  end

  def test_an_empty_body_verifies_when_that_is_what_was_signed
    assert verify("", header_for("", NOW))
  end

  # §10.9 THE PINNED CROSS-LANGUAGE VECTOR. If this fails, this
  # implementation is wrong -- the digest is cross-checked against the other
  # bindings and against the producer in apps/worker.
  def test_pinned_delivery_vector
    secret = "whsec_test"
    body = '{"id":"evt_1"}'
    header = "t=1700000000,v1=c89214b5b5da833daed6f0b8c5bb6bd58cea9022bd80ccc78230f3942d632925"

    assert_equal 14, body.bytesize, "the vector is those exact 14 bytes, no trailing newline"

    # Both ways of admitting a 2023 timestamp, because both are documented.
    assert Chatly.verify_webhook_signature(body, header, secret, Float::INFINITY)
    assert Chatly.verify_webhook_signature(body, header, secret, 300, now: 1_700_000_000)

    # ...and the same delivery with the digest over the body alone is
    # rejected.
    body_only = OpenSSL::HMAC.hexdigest("SHA256", secret, body)

    refute Chatly.verify_webhook_signature(body, "t=1700000000,v1=#{body_only}", secret,
                                           Float::INFINITY)
  end

  def test_pinned_vector_digest_is_reproduced_by_this_implementation
    digest = OpenSSL::HMAC.hexdigest("SHA256", "whsec_test", '1700000000.{"id":"evt_1"}')

    assert_equal "c89214b5b5da833daed6f0b8c5bb6bd58cea9022bd80ccc78230f3942d632925", digest
  end

  def test_secure_compare_does_not_raise_on_a_length_mismatch
    refute Chatly::Webhooks.secure_compare("abc", "abcd")
    assert Chatly::Webhooks.secure_compare("abc", "abc")
  end
end
