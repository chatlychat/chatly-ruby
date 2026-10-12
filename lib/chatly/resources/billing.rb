# frozen_string_literal: true

module Chatly
  module Resources
    # Plans and usage.
    #
    # `client.billing`
    #
    # Reads only. Nothing here starts, changes or cancels a subscription:
    # those routes require a signed-in person with billing permission, and a
    # workspace key is not a person.
    class Billing < Base
      PATH = "/v1/billing"

      # The plan catalogue -- what is on offer, with limits and prices.
      def plans(query = {})
        http_get("#{PATH}/plans", query)
      end

      # This workspace's current usage against its plan limits. The call to
      # make before a bulk import, so you find the ceiling before the import
      # does.
      def usage(query = {})
        http_get("#{PATH}/usage", query)
      end
    end
  end
end
