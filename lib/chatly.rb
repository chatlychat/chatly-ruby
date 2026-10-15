# frozen_string_literal: true

# Chatly -- the official Ruby SDK for the Chatly live-chat and customer
# messaging platform.
#
#   require "chatly"
#
#   client = Chatly::Client.new(ENV.fetch("CHATLY_API_KEY"))
#   client.conversations.auto_list(limit: 50).each do |conversation|
#     puts conversation["subject"]
#   end
#
# This is a BACKEND SDK. It authenticates with a workspace API key (`ck_...`)
# from server-side code. The key is a bearer credential for an entire
# workspace, so it must never reach a browser -- use `@chatlychat/sdk-js`
# there.
#
# Zero runtime dependencies: `net/http`, `json`, `openssl`, `securerandom`,
# `time` and `uri`, all from the standard library. You should not have to
# inherit our dependency tree to send a message.
#
# Four things need no client at all, because they are pure functions:
#
#   Chatly.identity_hash(secret, external_id)
#   Chatly.verify_webhook_signature(body, header, secret)
#   Chatly.verify_chatly_signature(surface:, body:, headers:, secret:)
#   Chatly::VERSION
# Load order matters in one place: `errors` and `transport` define constants
# that the resources and the client close over, so they come first. Plain
# `require_relative` throughout -- no autoload, no `Dir.glob` over the lib
# directory. A glob loads whatever happens to be on disk, in an order that
# depends on the filesystem, which is how a half-deleted file keeps working
# on one machine and breaks on another.
require_relative "chatly/version"
require_relative "chatly/errors"
require_relative "chatly/transport"
require_relative "chatly/pagination"
require_relative "chatly/identity"
require_relative "chatly/webhooks"
require_relative "chatly/signatures"
require_relative "chatly/resources/base"
require_relative "chatly/resources/ai"
require_relative "chatly/resources/billing"
require_relative "chatly/resources/bot_routes"
require_relative "chatly/resources/bots"
require_relative "chatly/resources/brands"
require_relative "chatly/resources/canvas_steps"
require_relative "chatly/resources/channels"
require_relative "chatly/resources/contacts"
require_relative "chatly/resources/conversations"
require_relative "chatly/resources/customer_card_endpoints"
require_relative "chatly/resources/customer_cards"
require_relative "chatly/resources/docs_sources"
require_relative "chatly/resources/email_templates"
require_relative "chatly/resources/events"
require_relative "chatly/resources/kb"
require_relative "chatly/resources/knowledge_gaps"
require_relative "chatly/resources/macros"
require_relative "chatly/resources/reports"
require_relative "chatly/resources/search"
require_relative "chatly/resources/tickets"
require_relative "chatly/resources/triggers"
require_relative "chatly/resources/visitors"
require_relative "chatly/resources/webhooks"
require_relative "chatly/resources/workspace"
require_relative "chatly/client"

module Chatly
  # Sugar for `Chatly::Client.new`.
  #
  #   chatly = Chatly.client(ENV.fetch("CHATLY_API_KEY"))
  def self.client(key = nil, **options)
    Client.new(key, **options)
  end
end
