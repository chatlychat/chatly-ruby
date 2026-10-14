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
      # Which workspace is this key for? A bare Array, and for a key it holds
      # exactly ONE entry.
      #
      # `GET /v1/workspaces/me` is the cross-workspace route -- for a person
      # it lists every workspace they are a member of -- so for a credential
      # minted in one workspace it is a list of one. That makes it the cheap
      # way to confirm which tenant a key actually points at, which is a
      # different question from {Chatly::Client#me}'s "is this key real".
      #
      # An Array rather than an object even in the one-entry case, because the
      # route's shape is set by the person's answer and a key does not get its
      # own schema.
      #
      # `role` is the SYNTHETIC `restricted` every key is given, not a stored
      # membership role. That is the honest value: what a key may do is its
      # scope set, which {Chatly::Client#me} answers. Reporting `owner` here
      # because the person who created the key was one would overstate the
      # credential.
      #
      # It answers on a SUSPENDED workspace, deliberately -- it is how a
      # caller discovers the others, and a user stranded in a suspended
      # workspace could otherwise switch but not see what to switch to.
      def mine(query = {})
        http_get("/v1/workspaces/me", query)
      end

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
      #
      # `GET /v1/agents` has no handler at all -- the agents controller
      # serves only this and one per-user route -- so there is no
      # key-accessible way to list the people holding a seat.
      def agent_skills(query = {})
        http_get("/v1/agents/skills", query)
      end

      # Every scope a key may be GRANTED -- `[{"value", "group"}]`, where
      # `group` is the part of the name before the first colon.
      #
      # The second of exactly two routes on the api-keys controller a key may
      # call ({Chatly::Client#whoami} is the other); managing keys with a key
      # stays closed, because that is a privilege-escalation shape and a
      # static vocabulary of permission NAMES is not.
      #
      # It was closed once, and the reason it was opened is the useful part:
      # the 403 it returned pointed the caller at the very endpoint it was
      # refusing, so an integrator could not turn "which scope does this
      # need?" into a lookup and learned each scope by provoking a 403
      # instead.
      #
      # This list is deliberately NARROWER than the product's full permission
      # set -- it is the grantable set, pinned against the routes that
      # actually accept a key. `POST /v1/api-keys` validates `scopes` as a
      # bare string array, so the create route will accept names that never
      # appear here and the key will then be refused by everything.
      def key_scopes(query = {})
        http_get("/v1/api-keys/scopes", query)
      end

      # A census of every credential this workspace holds, across nine
      # tables: existence, location and timestamps, never a value.
      #
      # `{"items", "total", "truncated"}` -- an object that carries `items`
      # and NO cursor, and it cannot ever become a page: the rows come from
      # nine tables whose ids are a mix of UUID v4 and v7, so there is no
      # orderable key across them and a cursor would hand out an unrelated
      # second page. `total` is just the length.
      #
      # **Read `truncated` first.** Each source is read with a per-source
      # cap, and `true` means the census is incomplete -- so an absent
      # credential may simply not have been reached.
      #
      # **And read `rotatedAtBasis` / `lastUsedBasis` before acting on a nil
      # timestamp.** `"none"` means nothing in the product records that fact
      # (most of the nine sources have no rotated-at column at all), while
      # `"column"` or `"derived"` means it was looked up and the credential
      # really has not been rotated or used. Treating the first as "never
      # used" is how a webhook secret that signs a delivery every minute gets
      # revoked.
      #
      # Two more traps in the rows: `id` is a synthetic stable
      # `source:rowid[:keypath]` string and NOT a database id (`resourceId`
      # is), and `status: "inactive"` does not mean safe to ignore -- the row
      # still holds live credential material. `surfaces` is plural on purpose:
      # one secret can protect two features, and a singular field once told
      # an operator that rotating it was safe for the second one.
      #
      # This is the one route on this surface requiring TWO permissions --
      # `workspace:write` AND `integrations:read` -- because it spans
      # resources guarded at different widths and the guard ANDs them.
      def secrets(query = {})
        http_get("/v1/workspace/secrets", query)
      end
    end
  end
end
