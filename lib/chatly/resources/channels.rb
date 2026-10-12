# frozen_string_literal: true

module Chatly
  module Resources
    # Channels -- the mediums conversations arrive on (web, email, WhatsApp,
    # SMS, and the rest).
    #
    # `client.channels`
    #
    # Read-only, and deliberately so: channel CONFIGURATION needs
    # `channels:write`, which no key-accessible route grants. A `create` or
    # `update` method here would compile, document and then fail with a 403
    # in somebody else's production. Configure channels in the dashboard.
    class Channels < Base
      PATH = "/v1/channels"

      # Every channel in the workspace. Not paginated -- there are a handful.
      #
      # Worth reading the `originsRestricted` field on a web channel: an
      # EMPTY allowed-origins list means "any origin", which is invisible in
      # the JSON unless you know that, so the API reports the distinction
      # explicitly.
      def list(query = {})
        http_get(PATH, query)
      end

      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end
    end
  end
end
