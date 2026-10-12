# frozen_string_literal: true

require_relative "test_helper"
require "openssl"

# CONTRACT.md §10.8 -- the pinned identity-hash vector.
#
# "This vector is computed and cross-checked in two implementations. If
# yours disagrees, yours is wrong."
class IdentityTest < ChatlyTest
  PINNED = "5e26772dce97d5ba995796e621f83f2e97e6f8c3f9386dbf153a98ab24c10271"

  def test_pinned_vector
    assert_equal PINNED, Chatly.identity_hash("sek_test_secret", "user_42")
  end

  def test_the_digest_is_lowercase_hex_of_sha256_length
    digest = Chatly.identity_hash("sek_test_secret", "user_42")

    assert_equal 64, digest.length
    assert_match(/\A[0-9a-f]{64}\z/, digest)
  end

  def test_it_is_hmac_of_the_external_id_under_the_secret_and_not_the_other_way_round
    # Swapping the arguments is the easy mistake, and it produces a
    # perfectly valid-looking digest that the widget rejects with no clue.
    swapped = Chatly.identity_hash("user_42", "sek_test_secret")

    refute_equal PINNED, swapped
  end

  def test_it_is_not_a_plain_sha256_of_either_input
    refute_equal Chatly.identity_hash("sek_test_secret", "user_42"),
                 OpenSSL::Digest::SHA256.hexdigest("user_42")
    refute_equal Chatly.identity_hash("sek_test_secret", "user_42"),
                 OpenSSL::Digest::SHA256.hexdigest("sek_test_secretuser_42")
  end

  def test_it_is_stable
    assert_equal Chatly.identity_hash("s", "u"), Chatly.identity_hash("s", "u")
  end

  def test_a_different_id_or_secret_changes_the_digest
    base = Chatly.identity_hash("sek_test_secret", "user_42")

    refute_equal base, Chatly.identity_hash("sek_test_secret", "user_43")
    refute_equal base, Chatly.identity_hash("sek_other_secret", "user_42")
  end

  # HMAC accepts an empty key and an empty message and returns a valid
  # digest, so without these checks an unset ENV var produces a hash the
  # widget silently refuses.
  def test_an_empty_secret_is_rejected
    error = assert_raises(ArgumentError) { Chatly.identity_hash("", "user_42") }
    assert_match(/secret is empty/, error.message)
    assert_raises(ArgumentError) { Chatly.identity_hash(nil, "user_42") }
  end

  def test_an_empty_external_id_is_rejected
    error = assert_raises(ArgumentError) { Chatly.identity_hash("sek_test_secret", "") }
    assert_match(/external_id is empty/, error.message)
    assert_raises(ArgumentError) { Chatly.identity_hash("sek_test_secret", nil) }
  end

  def test_a_non_string_id_is_stringified_consistently
    assert_equal Chatly.identity_hash("s", "42"), Chatly.identity_hash("s", 42)
  end

  def test_it_needs_no_client
    # A pure function on the module: no key, no network, nothing to
    # construct. The secret must never leave your backend and this is the
    # only thing that touches it.
    assert_respond_to Chatly, :identity_hash
    assert_equal PINNED, Chatly.identity_hash("sek_test_secret", "user_42")
  end

  def test_utf8_ids_are_hashed_over_their_bytes
    digest = Chatly.identity_hash("sek", "user_é")

    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "sek", "user_é"), digest
  end
end
