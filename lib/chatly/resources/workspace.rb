# frozen_string_literal: true

module Chatly
  module Resources
    # Workspace configuration and directories.
    #
    # `client.workspace`
    #
    # Grouped by what they answer -- "what is configured in this workspace?"
    # -- rather than by URL prefix: `settings` lives under
    # `/v1/workspace/settings` while the rest are top-level collections
    # (`/v1/labels`, `/v1/inboxes`, `/v1/teams/{id}/members`,
    # `/v1/agents/skills`). They are gathered here because an integration
    # resolving a name to an id needs all of them.
    #
    # All reads. Creating a label, an inbox or a team is not key-accessible.
    class Workspace < Base
      # Workspace-level settings: branding, business hours, defaults.
      def settings(query = {})
        http_get("/v1/workspace/settings", query)
      end

      # Conversation labels. Resolve a label name to its id here before
      # filtering a list by it.
      def labels(query = {})
        http_get("/v1/labels", query)
      end

      # Inboxes. An inbox is the routing destination a channel feeds.
      def inboxes(query = {})
        http_get("/v1/inboxes", query)
      end

      # The roster of one team.
      #
      # Takes a TEAM id, which has to come from the team's dashboard URL or
      # from a `teamId` on an object you already hold -- a macro with
      # `scope: "team"` carries one.
      #
      # Not cursor-paginated: a team roster is a subset of the workspace's
      # seats and the API answers with the whole list.
      def team_members(team_id, query = {})
        http_get(expand("/v1/teams/{id}/members", team_id), query)
      end

      # The workspace's skill taxonomy -- the distinct skill labels in use,
      # as `{"skills" => [...]}`.
      #
      # An empty array is a normal state for a workspace that has not set
      # any up, not an error. These are the labels skill-based routing
      # matches on.
      def agent_skills(query = {})
        http_get("/v1/agents/skills", query)
      end
    end
  end
end
