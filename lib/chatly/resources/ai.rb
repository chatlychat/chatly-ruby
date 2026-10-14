# frozen_string_literal: true

module Chatly
  module Resources
    # The AI layer: BYOK provider credentials, the subsidised-spend meter,
    # tone rules and custom HTTP tools.
    #
    # `client.ai`
    #
    # Two prefixes, deliberately not unified -- provider credentials live at
    # `/v1/ai-providers` and everything else under `/v1/ai/...`. They are
    # gathered on one namespace because they are one subject, not because
    # they share a URL.
    #
    # Nothing here records WHO changed it, which is why the whole set is open
    # to a key: a tone rule and a tool have no author column to fill in.
    class Ai < Base
      # The providers a key may be stored for. The path segment of
      # {#test_provider} is parsed against this list server-side, so a fourth
      # name is a 400 and not the 404 an unknown id would give you.
      PROVIDERS = %w[openai anthropic deepgram].freeze

      # The five tone categories. {#set_tone} is `.strict()` about them, so a
      # sixth name is a 400 -- one of the few places on this API where a
      # misspelling is visible instead of silently dropped.
      TONE_CATEGORIES = %w[empathy language formality personality warmth].freeze

      # BYOK provider status.
      #
      # An OBJECT -- `{"providers" => [...]}` -- not the bare array the name
      # suggests, and the array is a CONSTANT three rows: every supported
      # provider appears whether or not a key is stored. So
      # `providers["providers"].length` is not a count of what is set up;
      # read `configured` on each row.
      #
      # `keyHint` (four characters) is the only thing about a stored key any
      # response in this product ever carries. There is no route that returns
      # a provider key.
      def providers(query = {})
        http_get("/v1/ai-providers", query)
      end

      # Store a provider key. Answers 201 with
      # `{"provider", "validation", "reindexQueued"}`.
      #
      #   client.ai.add_provider(provider: "openai", apiKey: "sk-...")
      #
      # The field is `apiKey:`, not `key:` or `token:`; it is trimmed, 20-512
      # characters, and the literal redaction placeholder is refused.
      #
      # **A 201 does not mean the key works.** Read `validation["status"]`: a
      # key the provider actively REJECTS is a 422 carrying the provider's own
      # sentence, but a key we could not get an answer about -- provider 5xx,
      # a timeout, DNS, their rate limit -- is stored anyway as `unverified`.
      # Those are different outcomes and only one of them is an error.
      #
      # `reindexQueued` is the other half of the answer: storing an
      # embeddings-capable key re-indexes the knowledge base in the
      # background, so a non-zero count means work is now in flight. It is
      # capped, and the remaining articles index on their next publish.
      #
      # The ai-providers controller carries class-level
      # `@RequireIdempotencyKey()`, so this write is a 428 in production
      # without the header. This SDK always sends one.
      def add_provider(attributes = {}, **kwargs)
        http_post("/v1/ai-providers", merge_body(attributes, kwargs))
      end

      # Probe a stored key without changing it. Answers 201 (there is no
      # `@HttpCode`, so do not read the status as "created").
      #
      # The path segment is the PROVIDER NAME ({PROVIDERS}), not an id. A
      # provider with no stored key is a 404 rather than a `rejected`
      # validation -- "no key" and "a bad key" are different answers.
      #
      # A key that now fails auth is RECORDED as failing and left in place,
      # never deleted. Removing a provider key is deliberately not on this
      # surface: it destroys credential material that cannot be recovered,
      # and {#add_provider} already covers rotation.
      def test_provider(provider)
        http_post(expand("/v1/ai-providers/{provider}/test", provider))
      end

      # Subsidised AI spend against this workspace's cap.
      #
      # `budget`, `remaining` and `utilization` are NULLABLE, and null is
      # success: it means an uncapped plan, not a missing field.
      #
      # The spend figures are not interchangeable. `spent` (platform spend) is
      # the only one `budget` bounds; `byokSpent` is metered and never capped;
      # `totalSpent` is the pair. Presenting `spent` as "this workspace's AI
      # spend" shows a BYOK-heavy workspace a few dollars of a large bill.
      #
      # Note the permission: this one route wants `workspace:billing:read`
      # where the rest of `/v1/ai` wants `ai:read`, so a key scoped for the AI
      # routes gets a 403 here and nowhere else in this namespace. The AI
      # service being down is a 503.
      def quota(query = {})
        http_get("/v1/ai/quota", query)
      end

      # Every tone rule, ordered by category then position. A bare Array --
      # not `{"items" => ...}` -- and already complete: at most 40 rows, so
      # there is nothing to page.
      def tone(query = {})
        http_get("/v1/ai/tone", query)
      end

      # Replace the WHOLE rule set, and read it back.
      #
      #   client.ai.set_tone([{ category: "warmth", rule: "Never say 'as per my last message'" }])
      #
      # A PUT, so this is not "add a rule": the set you send is the set that
      # survives and `[]` deletes every rule. At most 40 rules and at most 8
      # per category -- enforced here as well as at render time on purpose,
      # because a write silently trimmed when the prompt is assembled is a
      # rule the operator believes is live.
      #
      # The body is `{"rules" => [...]}` and is `.strict()` at both levels.
      # `rule` is trimmed, 3-400 characters; `enabled` defaults to true.
      #
      # It answers with the same BARE ARRAY {#tone} returns, re-read after the
      # write -- not `{"rules" => [...]}`, and not a 204.
      #
      # @param rules [Array<Hash>, Hash, nil] an Array is wrapped as
      #   `{"rules" => [...]}`; a Hash is sent as the body you built
      def set_tone(rules = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        case rules
        when nil then nil
        when Array then body = { rules: rules }.merge(body)
        when Hash then body = rules.merge(body)
        else
          raise ArgumentError, "ai.set_tone: rules must be an Array of rule Hashes"
        end
        # `rules` is required and the body is strict, so a call with no rule
        # set is a 400 every time. Raise here instead: `set_tone([])` is how
        # you wipe the set, and it is worth making the difference between
        # "wipe it" and "I forgot the argument" visible at the call site.
        unless body.key?(:rules) || body.key?("rules")
          raise ArgumentError,
                "ai.set_tone: rules is required -- pass [] to delete every rule"
        end

        http_put("/v1/ai/tone", body)
      end

      # Turn a prose style guide into DRAFT rules. Answers 201 with
      # `{"rules", "note"}` and SAVES NOTHING -- pass what comes back to
      # {#set_tone} if you want it kept. It spends an LLM call.
      #
      # The body is `{"styleGuide" => "..."}`, `.strict()`, trimmed, and
      # 40-20,000 characters.
      #
      # A draft's `category` is a free string here on purpose: the model may
      # name a sixth category, and {#set_tone} is where it has to become one
      # of {TONE_CATEGORIES}. So a draft can be refused by the very write it
      # was generated for, and that is the design rather than a bug. `note`
      # is nullable.
      def generate_tone(style_guide = nil, attributes = {}, **kwargs)
        body = merge_body(attributes, kwargs)
        body = { styleGuide: style_guide }.merge(body) unless style_guide.nil?
        http_post("/v1/ai/tone/generate", body)
      end

      # The rendered system instruction the rules currently produce --
      # `{"instruction" => "..."}`.
      #
      # `""` is the normal answer for a workspace that configured nothing: no
      # house style is invented to fill the gap.
      #
      # Read it when a rule seems not to apply. The rendered block is
      # TRUNCATED at a length limit, with a line saying so, rather than
      # dropped -- so a long rule set loses its tail here while {#tone} still
      # lists every row. This route is the one that shows what the model is
      # actually told.
      def tone_preview(query = {})
        http_get("/v1/ai/tone/preview", query)
      end

      # Custom HTTP tools the autonomous agent may call. A bare Array,
      # ordered by name.
      #
      # It includes DISABLED tools -- only deleted ones are filtered -- so
      # this is the configuration, not the set the agent will actually call.
      # Check `enabled` per row.
      #
      # Secret header VALUES never come back: you get `secretHeaderNames` and
      # `signingSecretSet`. An empty `secretHeaderNames` does not prove no
      # secrets are stored -- a row encrypted under a rotated key degrades to
      # an empty list rather than failing the whole read.
      #
      # There is no fetch-one route for a tool; this list is the only read.
      def tools(query = {})
        http_get("/v1/ai/tools", query)
      end

      # Declare a tool. Answers 201.
      #
      #   client.ai.create_tool(name: "order_status", description: "Look up an order",
      #                         urlTemplate: "https://api.example.com/orders/{orderId}")
      #
      # Only `name:`, `description:` and `urlTemplate:` are required.
      # `method:` defaults to GET, `timeoutSeconds:` to 20 (max 30),
      # `enabled:` to true, `parameters:` to `[]` (max 16). The field names
      # worth getting right are the ones that read like something shorter:
      # `urlTemplate` (not `url`), `bodyTemplate` (not `body`),
      # `secretHeaders`, `signingSecret` (min 32 chars), `requiresApproval`
      # (false/true OR the strings `"agent"` / `"end_user"`),
      # `requiresVerifiedIdentity`.
      #
      # **The body schema is NOT strict**, so a misspelled key is stripped
      # and you get a 201 with that field unset. Read the tool back from
      # {#tools} after creating it if the field mattered.
      #
      # Three cross-field refusals that zod alone would not give you:
      # `requiresApproval: "end_user"` REQUIRES a `confirmTemplate`; a
      # `confirmTemplate` on any other approval mode is refused rather than
      # ignored; and `requiresVerifiedIdentity` (or any verified parameter
      # `source`) requires a `signingSecret`. The URL's host must also be
      # literal -- no placeholder in the hostname -- and must pass the
      # outbound SSRF guard, both as a 400 at write time.
      def create_tool(attributes = {}, **kwargs)
        http_post("/v1/ai/tools", merge_body(attributes, kwargs))
      end

      # Update a tool. A partial of the create body; omitted fields are left
      # as stored.
      #
      # `secretHeaders` and `signingSecret` are THREE-WAY: omit to keep the
      # stored value, `nil` to clear it, a value to replace it. Sending `nil`
      # because a form round-tripped an empty field wipes the credential.
      #
      # Coherence is checked against the MERGED row, so a one-key patch can
      # be a 400 over a field it never mentions -- `{confirmTemplate: nil}` on
      # an `end_user` tool, for instance. A missing id is a 404 here, unlike
      # {#delete_tool}.
      def update_tool(id, attributes = {}, **kwargs)
        http_patch(expand("/v1/ai/tools/{id}", id), merge_body(attributes, kwargs))
      end

      # Soft-delete a tool.
      #
      # **200 with `{"deleted" => true}`, not a 204** -- `macros.delete` is
      # the only genuine empty body on this surface.
      #
      # And `deleted` is a literal: there is nothing to branch on, because
      # **this route never 404s.** The update is unconditional and the row
      # count is not checked, so an unknown id, an already-deleted id and an
      # id in another workspace all answer 200 `{"deleted" => true}`. If you
      # need to know whether a tool existed, read {#tools} first.
      #
      # It is a soft delete that also forces `enabled: false`. The row stays
      # and so does its NAME -- re-creating a tool with the same name works
      # only because the list filters deleted rows.
      def delete_tool(id)
        http_delete(expand("/v1/ai/tools/{id}", id))
      end
    end
  end
end
