# frozen_string_literal: true

require "openssl"

module Chatly
  # Widget identity verification -- the backend half.
  #
  # When a workspace turns identity verification on, the widget must prove
  # that the `externalId` it claims was issued by your backend rather than
  # typed into a browser console. Without it, anyone can open a chat as
  # anyone else's account and read that account's history.
  #
  # Your server computes the digest; the browser only ever sees the digest.
  # The secret must never reach a browser, a mobile app, or a source map.
  #
  #   user_hash = Chatly.identity_hash(ENV.fetch("CHATLY_IDV_SECRET"), user.id)
  #   # then render:
  #   #   Chatly("identify", { externalId: "<%= user.id %>",
  #   #                        userHash: "<%= user_hash %>",
  #   #                        email: "<%= user.email %>" })
  #
  # @param secret [String] the workspace's identity-verification secret
  # @param external_id [String] your own stable id for the user
  # @return [String] lowercase hex HMAC-SHA256 of external_id under secret
  def self.identity_hash(secret, external_id)
    # Both empty checks exist because both empty values are silent failures
    # otherwise: HMAC happily accepts an empty key and an empty message and
    # returns a perfectly valid digest, which the widget would then reject
    # with no clue why. An unset ENV var is the common cause.
    raise ArgumentError, "identity_hash: secret is empty" if secret.nil? || secret.to_s.empty?
    raise ArgumentError, "identity_hash: external_id is empty" if external_id.nil? || external_id.to_s.empty?

    OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, external_id.to_s)
  end
end
