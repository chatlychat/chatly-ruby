# frozen_string_literal: true

module Chatly
  module Resources
    # The five overridable transactional emails.
    #
    # `client.email_templates`
    #
    # This is the override layer, not a mail sender: each kind has a built-in
    # subject and body, and a workspace may replace one of them. Removing an
    # override puts the workspace back on the built-in as it is TODAY, not on
    # a snapshot of the copy that was there when you overrode it.
    class EmailTemplates < Base
      PATH = "/v1/email-templates"

      # The five kinds. This is a PATH segment, not an id, and an unknown
      # value is a 400 from the handler's own parser rather than a 404 --
      # deliberately, so a bad value cannot reach a Postgres enum and come
      # back as a 500.
      #
      # `plain` -- the ordinary conversation email -- is not overridable and
      # is not here.
      KINDS = %w[
        workspace_invite
        trial_ending_reminder
        conversation_cap_warning
        hired_agent_engagement_invite
        hired_agent_engagement_started
      ].freeze

      # All five, with each workspace override or nil.
      #
      # The CATALOGUE, not the rows: this is always exactly five entries for
      # every workspace, and `override` is nil where the workspace is still on
      # the built-in. So the length is the number of KINDS and never the
      # number of overrides -- count the non-nil `override`s for that.
      def list(query = {})
        http_get(PATH, query)
      end

      # Override one template. A PUT, answering 200 with the catalogue entry
      # -- the same shape a {#list} row has, not an acknowledgement.
      #
      #   client.email_templates.update("workspace_invite",
      #                                 subject: "Join {{workspaceName}}",
      #                                 body: "Hello {{inviteeName}}...")
      #
      # The body is `.strict()` and holds only `{subject, body}`: `kind` lives
      # in the path, and including it in the body is a 400. {#preview} wants
      # it the other way round, which is the trap between the two.
      #
      # Both fields are required, trimmed, then length-checked (subject 300,
      # body 10,000) -- so a subject of only spaces is REFUSED rather than
      # stored as an empty one.
      #
      # Idempotent by construction: one row per workspace per kind, upserted.
      def update(kind, attributes = {}, **kwargs)
        http_put(expand("#{PATH}/{kind}", kind), merge_body(attributes, kwargs))
      end

      # Drop the override and go back to the built-in.
      #
      # **200 with `{"restored" => <boolean>}`, not a 204**, and that boolean
      # is the whole answer: `false` means the workspace was ALREADY on the
      # built-in, which is a success and not a 404. It does not return the
      # restored template, because restoring is deleting a row -- there is
      # nothing to return but the built-in, which {#list} will show you.
      def delete(kind)
        http_delete(expand("#{PATH}/{kind}", kind))
      end

      # Render a draft without saving it. Answers 201 with
      # `{"subject", "html", "text", "unknownTokens"}`.
      #
      #   client.email_templates.preview(kind: "trial_ending_reminder",
      #                                  subject: "{{daysLeft}} days left",
      #                                  body: "Hi {{firstName}}...")
      #
      # Here `kind` IS a body field and all three are required -- the mirror
      # image of {#update}, where `kind` in the body is a 400. `subject` and
      # `body` may be empty strings on this route only.
      #
      # `unknownTokens` is why you would call it: tokens you wrote that this
      # kind does not supply. An empty array is the healthy answer, and it
      # matters because the renderer leaves an unknown token VISIBLE in sent
      # mail rather than blanking it.
      def preview(attributes = {}, **kwargs)
        http_post("#{PATH}/preview", merge_body(attributes, kwargs))
      end
    end
  end
end
