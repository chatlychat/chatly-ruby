# frozen_string_literal: true

module Chatly
  module Resources
    # Questions the knowledge base could not answer.
    #
    # `client.knowledge_gaps`
    #
    # A gap is recorded when a RAG query finds nothing usable. The namespace
    # is three routes: read the queue, move a gap along, or have the model
    # draft the missing article.
    class KnowledgeGaps < Base
      PATH = "/v1/knowledge-gaps"

      # The four statuses. `drafted` is the one that is easy to forget and is
      # settable by hand as well as reached through {#draft}.
      STATUSES = %w[open drafted resolved dismissed].freeze

      # The gap queue, most-asked first (`occurrences` descending). A bare
      # Array -- a queue to work through, not a log to page.
      #
      # Two query parameters and NEITHER is validated the way you would hope:
      # an unrecognised `status:` is SILENTLY IGNORED and you get the
      # unfiltered list with a 200 (the handler `safeParse`s it and drops the
      # filter on failure), and `limit:` is clamped to 1-200 with a default of
      # 100 rather than rejected -- a non-numeric value falls back to 100.
      #
      # There is no cursor, and that is sound rather than an omission: the
      # recorder caps a workspace at 200 open gaps, so the list is the list.
      def list(query = {})
        http_get(PATH, query)
      end

      # Set a gap's status.
      #
      #   client.knowledge_gaps.update(gap_id, "dismissed")
      #
      # `status` is the ONLY mutable field -- there is no question text to
      # edit and no notes -- and the body is `.strict()`, so anything else is
      # a 400. The handler's own name for this is `setStatus`, which is the
      # honest one; `update` is what the cross-language manifest calls it.
      #
      # A gap that is not this workspace's is a 404.
      def update(id, status = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { status: status }.merge(body) unless status.nil?
        http_patch(expand("#{PATH}/{id}", id), body)
      end

      # Have the model draft an article from the gap's own conversation.
      # Answers 201 with `{"gap", "articleId", "reason"}` -- note the gap is
      # NESTED rather than returned at the top level.
      #
      # **A 201 can mean "no article was written".** When the model judges the
      # conversation holds no reusable answer you get `articleId: nil` with a
      # non-nil `reason` and the gap untouched; that is an answer, not a
      # failure. On success `articleId` is set, `reason` is nil, and the gap
      # comes back at status `drafted` -- not `resolved`, because nobody has
      # read the draft yet.
      #
      # It inserts a `draft` KB article: never published, and with no author,
      # since the model wrote it. A gap with no conversation behind it (or an
      # empty transcript) is a 400 from the service instead of this shape.
      # The transcript it reads is capped.
      #
      # **This route calls an LLM, so it is slow.** The client's default
      # timeout is 15 seconds; raise it for this call:
      #
      #   Chatly::Client.new(key, timeout: 60).knowledge_gaps.draft(gap_id)
      def draft(id)
        http_post(expand("#{PATH}/{id}/draft", id))
      end
    end
  end
end
