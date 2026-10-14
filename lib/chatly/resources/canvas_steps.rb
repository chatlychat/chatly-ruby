# frozen_string_literal: true

module Chatly
  module Resources
    # The back half of an ASYNC canvas step.
    #
    # `client.canvas_steps`
    #
    # Your canvas endpoint answered `{"pending": true}` -- because a payment
    # needed 3-D Secure, a fraud check had to clear, or a PSP was slow -- and
    # was given a correlation id. These two routes are what you do with it
    # minutes later, from a backend process holding a `ck_` key and no visitor
    # session. That caller is exactly the one a ten-second synchronous timeout
    # could not serve, which is the whole reason the async form exists.
    class CanvasSteps < Base
      PATH = "/v1/canvas-steps"

      # How long a pending step stays claimable. After that {#resolve} is a
      # 409 rather than a 404 -- a lapse and an unknown id are different
      # answers.
      TTL_MINUTES = 10

      # Read a pending step: `{"id", "conversationId", "messageId",
      # "canvasId", "reason", "actionId", "status", "expiresAt", "settledAt",
      # "createdAt"}`.
      #
      # It carries NO canvas, by design -- this is status and expiry, not the
      # content you are about to replace.
      #
      # A 404 means the id is unknown, belongs to another workspace, or the
      # step has expired, and this route cannot tell you which --
      # deliberately: an id that reported "expired" rather than "unknown"
      # would confirm that somebody else's step id is real.
      #
      # One 404 that surprises people: the pending row is written AFTER we
      # answer the visitor, so reading or resolving from inside the request
      # that returned `{"pending": true}` races the insert. Resolve from the
      # job that finishes the work, not from the handler that started it.
      def get(id)
        http_get(expand("#{PATH}/{id}", id))
      end

      # Post the real next step. Answers 201 with
      # `{"stepId", "conversationId", "messageId", "canvasId"}`.
      #
      #   client.canvas_steps.resolve(step_id, canvas: { v: 1, canvasId: "receipt",
      #                                                  blocks: [...] })
      #
      # The body is `{"canvas" => ...}` and is **strict** -- any other key is
      # a 400 rather than a silently dropped field. The canvas needs `v: 1`
      # and a `canvasId`, and exactly ONE of `blocks` (1-20) or `app`;
      # `inputs` without `actions` is refused, and so are duplicate ids.
      # `issuedAt` is accepted and then overwritten, so there is no point
      # sending one. `hostEvent` is deliberately NOT accepted here -- fire it
      # on the synchronous `{"pending": true}` answer instead.
      #
      # **Single-use by construction, not by an idempotency key.** The
      # claiming UPDATE carries `status = 'pending'` in its WHERE clause, so
      # exactly one resolve wins and a second is told the step is already
      # resolved. That is why the route honours an `Idempotency-Key` without
      # demanding one: requiring the header would add a 428 for an integrator
      # who forgot it, in exchange for a guarantee the route already makes.
      #
      # So a retry after a timeout is safe whether or not you pinned a key --
      # and a retry whose first attempt SUCCEEDED is told so (409, with the
      # step's `status`), which is the answer you want rather than a second
      # canvas in the thread.
      #
      # It replaces the message's canvas AND its plain-text body, then
      # publishes `message.updated`, so an open widget updates with no reload.
      def resolve(id, attributes = {}, **kwargs)
        http_post(expand("#{PATH}/{id}/resolve", id), merge_body(attributes, kwargs))
      end
    end
  end
end
