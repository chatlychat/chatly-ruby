# chatly

The official Ruby SDK for [Chatly](https://chatlychat.com) — a live chat and
customer messaging platform. This gem talks to Chatly's REST API from your
**server**: read and reply to conversations, upsert contacts, file and move
tickets, search the knowledge base, record product events, verify webhook
deliveries and pull reports.

Zero runtime dependencies. Ruby >= 3.0.

```bash
gem install chatly
```

```ruby
# Gemfile
gem "chatly", "~> 0.1"
```

## Quickstart

```ruby
require "chatly"

chatly = Chatly::Client.new(ENV.fetch("CHATLY_API_KEY"))

puts chatly.whoami["scopes"]                        # check the key first

contact = chatly.contacts.upsert(externalId: "user_42", email: "ada@example.com")
chatly.events.track(contactId: contact["id"], name: "trial_started")

chatly.conversations.auto_list(limit: 50).each do |conversation|
  puts "#{conversation['id']}: #{conversation['subject']}"
  chatly.conversations.send_message(conversation["id"], body: "Thanks — looking now!")
end
```

## Getting a key, and where it may live

The credential is a **workspace API key**, created in the Chatly dashboard
under Settings → API keys. It looks like `ck_live_…`.

> **This is a backend SDK.** The key is a bearer credential for an entire
> workspace: anything holding it can read every conversation in that
> workspace. Keep it in an environment variable or a secrets manager. Never
> ship it to a browser, a mobile app or a source map, and never put it in a
> client-side bundle — for in-page chat use the browser SDK
> (`@chatlychat/sdk-js`), which authenticates differently on purpose.

A key reaches 140 of the API's 886 routes. The rest need a signed-in person
and answer a key with `403` — a reaction records _who_ reacted, and a key is
not a person. This gem only wraps routes a key can actually use; see
[The escape hatch](#the-escape-hatch) for the ones without a typed method.

## Construction

```ruby
Chatly::Client.new("ck_live_…")                    # positional
Chatly::Client.new(api_key: ENV.fetch("CHATLY_API_KEY"))

Chatly::Client.new(
  ENV.fetch("CHATLY_API_KEY"),
  api_url: "http://localhost:3001",                # another environment, or a test server
  timeout: 15,                                     # seconds; connect, read and write
  retries: 3,                                      # total attempts, including the first
  retry_policy: Chatly::RetryPolicy.new(attempts: 5, base_delay: 1.0),
  transport: MyPooledTransport.new,                # anything responding to #call
  user_agent: "acme-billing-sync/2.1"
)
```

| Option         | Default                      | Notes                                                                                |
| -------------- | ---------------------------- | ------------------------------------------------------------------------------------ |
| `api_key`      | —                            | required; an empty key raises `ArgumentError` at construction, not at the first call |
| `api_url`      | `https://api.chatlychat.com` | the production host. Override for another environment, or a test server              |
| `timeout`      | `15`                         | seconds, applied to connect, read and write separately                               |
| `retries`      | `3`                          | see [Retries](#retries)                                                              |
| `retry_policy` | —                            | full control; overrides `retries`                                                    |
| `transport`    | `Chatly::NetHttpTransport`   | see [Injecting a transport](#injecting-a-transport)                                  |
| `user_agent`   | `chatly-sdk-ruby/<version>`  |                                                                                      |

A client is immutable after construction and holds no connection state, so
sharing one across threads is fine.

## Shapes: what goes out and what comes back

**Responses are plain Ruby `Hash`es with the API's own keys**, which are
camelCase: `contact["externalId"]`, `page.raw["nextCursor"]`. Nothing is
converted to snake_case and nothing is wrapped in a model class.

**Request keys are sent exactly as you write them**, at every depth:

```ruby
chatly.contacts.upsert(externalId: "user_42")   # correct
chatly.contacts.upsert(external_id: "user_42")  # silently incomplete
```

The second call succeeds with a `201` and ignores the field. The API
validates bodies against a schema that **drops keys it does not recognise**,
so a "helpful" rename in this gem would turn a complete write into a partial
one that reports success. Write camelCase and you are writing what the API
reads. A `Hash` with String keys works too, and is the way to send a key
whose spelling you want to be certain of:

```ruby
chatly.contacts.upsert("externalId" => "user_42", "attributes" => { "plan_tier" => "pro" })
```

Keys _inside_ `attributes` and `properties` are yours — they are
customer-defined and are never touched.

## Method reference

55 methods across 13 namespaces. `client.<namespace>.<method>`.

### Credential

| Ruby     | HTTP                      |
| -------- | ------------------------- |
| `whoami` | `GET /v1/api-keys/whoami` |

Call it first. It returns the workspace the key belongs to and the scopes it
was granted, which turns a mis-scoped key into an obvious error at
integration time rather than a `403` from an unrelated endpoint weeks later.

### `contacts`

| Ruby                                   | HTTP                                  |
| -------------------------------------- | ------------------------------------- |
| `contacts.list(query = {})`            | `GET /v1/contacts`                    |
| `contacts.auto_list(query = {})`       | ↳ auto-paginating `Enumerator`        |
| `contacts.get(id)`                     | `GET /v1/contacts/{id}`               |
| `contacts.upsert(attrs)`               | `POST /v1/contacts`                   |
| `contacts.bulk_upsert(array_of_attrs)` | `POST /v1/contacts/bulk`              |
| `contacts.merge(id, merged_id)`        | `POST /v1/contacts/{id}/merge`        |
| `contacts.add_tags(id, tag)`           | `POST /v1/contacts/{id}/tags`         |
| `contacts.remove_tag(id, tag)`         | `DELETE /v1/contacts/{id}/tags/{tag}` |
| `contacts.unsubscribe(id, attrs = {})` | `POST /v1/contacts/{id}/unsubscribe`  |
| `contacts.journey(id)`                 | `GET /v1/contacts/{id}/journey`       |
| `contacts.auto_journey(id)`            | ↳ auto-paginating `Enumerator`        |

`upsert` fields: `externalId`, `email`, `phone`, `name`, `avatarUrl`,
`locale`, `timezone`, `attributes`. All optional, and the API matches an
existing contact before inserting — so calling it on every login updates
rather than duplicating.

`bulk_upsert` takes up to 5000 contacts per request.

`merge(id, merged_id)`: the contact in the **path** survives. Not reversible.
`merged_id` must be a UUID v7.

`add_tags` sends **one** tag per call — the route's body is
`{"tag": "..."}`. The plural name is the one in the cross-language method
list. Passing an Array raises `ArgumentError` rather than sending a body the
API would quietly drop:

```ruby
%w[vip churn-risk].each { |tag| chatly.contacts.add_tags(id, tag) }
```

`remove_tag` is a `DELETE` that **answers `200` with the surviving contact**,
not `204` — the same object the tag `POST` returns. It is not the only one:
see `conversations.cancel_scheduled`. On this surface `macros.delete` is the
only call that really answers with no body, and it is the only one that
returns `nil`.

`unsubscribe` defaults to opting the contact out. It is also how you opt
someone back in: `contacts.unsubscribe(id, unsubscribed: false)`.

`list` accepts `blocked: true` / `false`. Omitting it returns everything,
blocked contacts included — a block is a flag, not a deletion.

### `conversations`

| Ruby                                           | HTTP                                                         |
| ---------------------------------------------- | ------------------------------------------------------------ |
| `conversations.list(query = {})`               | `GET /v1/conversations`                                      |
| `conversations.auto_list(query = {})`          | ↳ auto-paginating `Enumerator`                               |
| `conversations.get(id)`                        | `GET /v1/conversations/{id}`                                 |
| `conversations.messages(id, query = {})`       | `GET /v1/conversations/{id}/messages`                        |
| `conversations.auto_messages(id, query = {})`  | ↳ auto-paginating `Enumerator`                               |
| `conversations.send_message(id, attrs)`        | `POST /v1/conversations/{id}/messages`                       |
| `conversations.unattended(query = {})`         | `GET /v1/conversations/unattended`                           |
| `conversations.auto_unattended(query = {})`    | ↳ auto-paginating `Enumerator`                               |
| `conversations.agent_handling(id)`             | `GET /v1/conversations/{id}/agent-handling`                  |
| `conversations.set_agent_handling(id, attrs)`  | `PUT /v1/conversations/{id}/agent-handling`                  |
| `conversations.generated_replies(id)`          | `GET /v1/conversations/{id}/generated-replies`               |
| `conversations.generate_reply(id, attrs = {})` | `POST /v1/conversations/{id}/generated-replies`              |
| `conversations.scheduled_messages(id)`         | `GET /v1/conversations/{id}/scheduled-messages`              |
| `conversations.schedule_message(id, attrs)`    | `POST /v1/conversations/{id}/scheduled-messages`             |
| `conversations.cancel_scheduled(scheduled_id)` | `DELETE /v1/conversations/scheduled-messages/{scheduled_id}` |

**`send_message`, not `send`.** The cross-language method list calls this one
`send`, and Ruby cannot: `send` is `Object#send`, Ruby's own "call this
method by name". A namespace that shadowed it would break metaprogramming,
serialisers and anything calling `obj.send(:foo)`. This is the only method in
the gem whose name differs from the shared list.

```ruby
chatly.conversations.send_message(conversation_id, body: "On it!")
chatly.conversations.send_message(conversation_id, body: "Checked billing.", kind: "note")
```

`body:` is the message text and is the only required field. `kind:` defaults
to `"text"`; the others are `"rich"`, `"note"` (an internal note the contact
never sees) and `"system_event"`. Who the message is attributed to is decided
by the API from the key: an unlinked key sends as `system` with no author, and
a key bound to a machine user sends as that agent.

`set_agent_handling(id, state:, reason: nil)` reports a bot's progress on a
thread. `state:` is `"in_progress"`, `"handed_off"` or `"handled"`, and
`reason:` is what the human who picks the thread up reads. **This pair of
routes requires a machine principal** — a key not bound to a machine user
gets a `403`.

`schedule_message(id, body:, sendAt:)` queues a send. `sendAt` must be a
String; `JSON.generate` does not render a `Time` as ISO-8601, so pass
`time.utc.iso8601` yourself.

`cancel_scheduled` takes the **scheduled message's** id, not the
conversation's — note the path. It answers `200` with the row it cancelled,
so the return value is a `Hash`, not `nil`.

### `tickets`

| Ruby                                        | HTTP                                                 |
| ------------------------------------------- | ---------------------------------------------------- |
| `tickets.list(query = {})`                  | `GET /v1/tickets`                                    |
| `tickets.auto_list(query = {})`             | ↳ auto-paginating `Enumerator`                       |
| `tickets.comments(id)`                      | `GET /v1/tickets/{id}/comments`                      |
| `tickets.for_conversation(conversation_id)` | `GET /v1/tickets/for-conversation/{conversation_id}` |
| `tickets.queues`                            | `GET /v1/tickets/queues`                             |
| `tickets.merge(id, loser_id)`               | `POST /v1/tickets/{id}/merge`                        |
| `tickets.split(id, attrs)`                  | `POST /v1/tickets/{id}/split`                        |
| `tickets.bulk(attrs)`                       | `POST /v1/tickets/bulk`                              |

`merge(id, loser_id)`: the ticket in the path survives; the loser keeps its
row and moves to status `merged`. There is no unmerge.

`split(id, title:, …)`: the path id is the **origin**, and the body describes
the new ticket. `title:` is required. `description`, `priority`, `type`,
`assigneeUserId` and `tags` inherit the origin's values when omitted. This
one **creates** a ticket, so retry it with a pinned idempotency key or you
will get two children.

```ruby
chatly.tickets.bulk(ids: ids, action: "status", payload: { status: "closed" })
```

`action:` is `"status"`, `"assign"`, `"priority"` or `"queue"`; `payload:`
carries `status`, `assigneeUserId` (null to unassign), `priority` or `queueId`
(null to remove from its queue). Up to 200 ids per call.

### `macros`

| Ruby                       | HTTP                     |
| -------------------------- | ------------------------ |
| `macros.list(query = {})`  | `GET /v1/macros`         |
| `macros.create(attrs)`     | `POST /v1/macros`        |
| `macros.update(id, attrs)` | `PATCH /v1/macros/{id}`  |
| `macros.delete(id)`        | `DELETE /v1/macros/{id}` |

A macro is a canned reply plus optional conversation actions. `create`
requires `name:` and `scope:` (`"workspace"`, `"team"` or `"personal"`), plus
reply text, at least one action, or both. `teamId:` is required when `scope:`
is `"team"`.

`list` query: `scope:`, `team:`, `query:`, `language:`. **It returns a plain
`Array`, not a `Chatly::Page`** — this route is not paginated: the API caps it
at 200 rows ordered by usage rank and answers with a bare array. There is no
`macros.auto_list`, because there is no cursor to walk.

### `kb` — knowledge base / help centre

| Ruby                           | HTTP                           |
| ------------------------------ | ------------------------------ |
| `kb.articles(query = {})`      | `GET /v1/kb/articles`          |
| `kb.auto_articles(query = {})` | ↳ auto-paginating `Enumerator` |
| `kb.article(slug)`             | `GET /v1/kb/articles/{slug}`   |
| `kb.collections`               | `GET /v1/kb/collections`       |

`article` takes a **slug**, not an id: `kb.article("how-to-reset-your-password")`.

### `search`

| Ruby                           | HTTP             |
| ------------------------------ | ---------------- |
| `search.query(q, params = {})` | `GET /v1/search` |

Full text across contacts, conversations, messages, tickets and KB articles.
`q` is required (1–256 characters). Also accepted: `kinds` (an Array), `from`
/ `to` (ISO-8601), `channelId`, `assigneeUserId`, `status`, `limit` (1–100,
default 25) and `cursor`.

```ruby
chatly.search.query("refund not received", limit: 10)
chatly.search.query("password reset", kinds: %w[kb article])
# => GET /v1/search?q=password%20reset&kinds=kb&kinds=article
```

### `events` — CDP

| Ruby                           | HTTP                           |
| ------------------------------ | ------------------------------ |
| `events.track(attrs)`          | `POST /v1/cdp/events`          |
| `events.list(query = {})`      | `GET /v1/cdp/events`           |
| `events.auto_list(query = {})` | ↳ auto-paginating `Enumerator` |

```ruby
chatly.events.track(contactId: contact["id"], name: "trial_started",
                    properties: { "plan" => "pro", "seats" => 3 })
```

`contactId:` (UUID v7) and `name:` are required. Pass `contactId:` to
`list`/`auto_list` to scope the stream to one person.

### `webhooks` — delivery log

| Ruby                                   | HTTP                                          |
| -------------------------------------- | --------------------------------------------- |
| `webhooks.deliveries(query = {})`      | `GET /v1/webhooks/deliveries`                 |
| `webhooks.auto_deliveries(query = {})` | ↳ auto-paginating `Enumerator`                |
| `webhooks.delivery(id)`                | `GET /v1/webhooks/deliveries/{id}`            |
| `webhooks.redeliver(id)`               | `POST /v1/webhooks/deliveries/{id}/redeliver` |

This is the delivery **history**; registering endpoints is not key-accessible.
`redeliver` queues the recorded payload against the endpoint's current URL
and the outcome appears as a _new_ attempt in the list. To verify an inbound
delivery, see [Webhook verification](#webhook-verification) — that needs no
client.

### `reports`

| Ruby                                       | HTTP                                   |
| ------------------------------------------ | -------------------------------------- |
| `reports.overview(query = {})`             | `GET /v1/reports/overview`             |
| `reports.agents(query = {})`               | `GET /v1/reports/agents`               |
| `reports.conversations_by_day(query = {})` | `GET /v1/reports/conversations-by-day` |
| `reports.sla(query = {})`                  | `GET /v1/reports/sla`                  |

All four take `days:` (the usual default is 30), or `from:` / `to:` as
ISO-8601. `business_hours: true` opts duration metrics into the workspace's
opening hours; it defaults to false because every figure the product shows is
calendar time. These are rollups, not lists — no cursor.

`reports.agents` is the per-agent performance report, broken down by agent.

### `channels`

| Ruby               | HTTP                    |
| ------------------ | ----------------------- |
| `channels.list`    | `GET /v1/channels`      |
| `channels.get(id)` | `GET /v1/channels/{id}` |

Reads only: channel configuration needs a permission no API key is granted,
so there is deliberately no `create` or `update` here rather than a method
that always fails. On a web channel, read `originsRestricted` — an **empty**
allowed-origins list means "any origin", which is invisible in the raw JSON.

### `billing`

| Ruby            | HTTP                    |
| --------------- | ----------------------- |
| `billing.plans` | `GET /v1/billing/plans` |
| `billing.usage` | `GET /v1/billing/usage` |

Reads only. `usage` is the call to make before a bulk import, so you find the
plan ceiling before the import does.

### `workspace`

| Ruby                              | HTTP                         |
| --------------------------------- | ---------------------------- |
| `workspace.settings`              | `GET /v1/workspace/settings` |
| `workspace.labels`                | `GET /v1/labels`             |
| `workspace.inboxes`               | `GET /v1/inboxes`            |
| `workspace.team_members(team_id)` | `GET /v1/teams/{id}/members` |
| `workspace.agent_skills`          | `GET /v1/agents/skills`      |

Grouped by what they answer — "what is configured in this workspace?" — not
by URL prefix. All reads; creating a label, an inbox or a team is not
key-accessible.

`team_members` takes a **team** id, which comes from the team's dashboard
URL or from a `teamId` on an object you already hold — a macro with
`scope: "team"` carries one.

`agent_skills` returns `{"skills": [...]}` — the distinct skill labels
skill-based routing matches on. An empty array is a normal state for a
workspace that has not set any up, not an error.

## Pagination

Ten endpoints are cursor-paginated, and each returns
`{ "items": [...], "nextCursor": "…" | null }` — with whatever the route puts
beside them. For each you get both the single page and an auto-paginating
`Enumerator`:

| Page                         | Enumerator                        |
| ---------------------------- | --------------------------------- |
| `contacts.list`              | `contacts.auto_list`              |
| `contacts.journey(id)`       | `contacts.auto_journey(id)`       |
| `conversations.list`         | `conversations.auto_list`         |
| `conversations.messages(id)` | `conversations.auto_messages(id)` |
| `conversations.unattended`   | `conversations.auto_unattended`   |
| `tickets.list`               | `tickets.auto_list`               |
| `kb.articles`                | `kb.auto_articles`                |
| `search.query(q)`            | `search.auto_query(q)`            |
| `events.list`                | `events.auto_list`                |
| `webhooks.deliveries`        | `webhooks.auto_deliveries`        |

Every other list-shaped method returns what the API returns — an `Array` or an
object — with no `Chatly::Page` wrapper and no `auto_*` twin, because a page
object over a cursorless route advertises a `nextCursor` the server never
offered and invites a paging loop that cannot terminate correctly.

```ruby
page = chatly.contacts.list(limit: 100)
page.items          # => [{...}, {...}]
page.next_cursor    # => "eyJ…" or nil
page.more?          # => true / false
page.size
page.raw            # the untouched response Hash
page.each { |c| … } # a Page is Enumerable over its own items

# the next page
chatly.contacts.list(limit: 100, cursor: page.next_cursor)
```

`auto_*` returns an `Enumerator`, so everything Ruby does to a lazy sequence
works, and only the pages you consume are fetched:

```ruby
chatly.contacts.auto_list(limit: 200).each { |c| import(c) }     # every page
chatly.contacts.auto_list.first(10)                              # one page
chatly.contacts.auto_list.lazy.select { |c| c["email"] }.first(3)
chatly.conversations.auto_messages(conversation_id).to_a
```

It stops on a null cursor, and it stops if the server ever hands back a
cursor it already gave — a repeated cursor would otherwise re-yield the same
page forever, raise nothing, and look like a hung job.

If you want page boundaries (to checkpoint a cursor, or to insert a page at a
time):

```ruby
Chatly::Pagination.each_page(limit: 500) { |q| chatly.contacts.list(q) }
                  .each { |page| MyModel.insert_all(page.items) }
```

A body that is **not** an envelope is an error here, not an empty page. If one
of these routes ever answers with a bare array or a plain object,
`Chatly::Page` raises a `Chatly::Error` with `code: "sdk_not_a_page"` rather
than handing back a page of nothing — a walker that yielded zero items and
returned normally would read as "this workspace is empty", which is a wrong
answer rather than a missing one. Two sibling SDKs shipped exactly that,
against `GET /v1/macros`.

**Never sort or page on `id`.** Ids in this product are a mix of UUID v4 and
v7, so id order is not time order. The cursor is the only correct sequence,
and it is opaque — do not parse it.

Query parameters: `cursor`, `limit`, `filter`, `sort`, `fields`. An Array
value repeats the key rather than comma-joining it, because to this API those
are different requests:

```ruby
chatly.tickets.list(filter: ["status:open", "priority:high"], sort: "-createdAt")
# => ?filter=status%3Aopen&filter=priority%3Ahigh&sort=-createdAt
```

## Errors

Every failure raises a `Chatly::Error` subclass. Nothing in this gem raises a
bare `RuntimeError`, and nothing returns an error as a value.

| Class                         | When     |                                                                    |
| ----------------------------- | -------- | ------------------------------------------------------------------ |
| `Chatly::AuthenticationError` | 401      | the key is missing, malformed or revoked                           |
| `Chatly::PermissionError`     | 403      | the key is valid but lacks the scope — or the route needs a person |
| `Chatly::NotFoundError`       | 404      | no such resource _in this workspace_                               |
| `Chatly::ConflictError`       | 409      | conflicting write; `#idempotency_conflict?` names the replay case  |
| `Chatly::ValidationError`     | 422, 400 | the request was understood and rejected                            |
| `Chatly::RateLimitError`      | 429      | carries `#retry_after` in seconds                                  |
| `Chatly::ServerError`         | 5xx      |                                                                    |
| `Chatly::TransportError`      | —        | DNS, connect, TLS, timeout; `#status` is `nil`                     |

All of them carry the same five fields, so you never have to parse a message
string to decide what happened:

```ruby
begin
  chatly.contacts.get(id)
rescue Chatly::NotFoundError => e
  e.status      # => 404
  e.code        # => "not_found"      (the API's machine-readable code)
  e.message     # => "No such contact"
  e.request_id  # => the x-request-id response header, when the server sent one
  e.body        # => the raw response text
  e.details     # => the API's structured context Hash, or nil
end
```

Branch on the class, not on the text:

```ruby
rescue Chatly::AuthenticationError
  abort "CHATLY_API_KEY is wrong"
rescue Chatly::PermissionError => e
  abort "key is missing a scope: #{e.message}"
rescue Chatly::RateLimitError => e
  sleep(e.retry_after || 5)
  retry
rescue Chatly::TransportError => e
  logger.warn("could not reach Chatly: #{e.message} (#{e.cause.class})")
end
```

`TransportError` is deliberately a different class from any HTTP status: "I
could not reach the API" and "the API said no" need different handling. Ruby's
own `Exception#cause` carries the underlying `SocketError`,
`Net::ReadTimeout` and so on.

Two notes on fields, so neither surprises you in production:

- `request_id` is read from the `x-request-id` response header. If the
  deployment you are talking to does not send that header, the field is
  `nil` — it is not synthesised.
- `retry_after` prefers the `Retry-After` header and falls back to
  `details["retryAfterSeconds"]` in the error body. A `Retry-After` expressed
  as an HTTP date is **not** parsed into seconds; the field stays `nil`
  rather than being misread as a small integer.

## Retries

Retried: connection failures, `429`, and `5xx`. Never retried: any other
`4xx` — a `422` will be a `422` next time too. Three attempts by default
(the first plus two retries), with exponential backoff and half jitter, so
two clients that failed together do not come back together.
`Retry-After` is honoured when present, clamped to 60 seconds so one upstream
header cannot park a web request for an hour.

```ruby
Chatly::Client.new(key, retries: 1)   # off
Chatly::Client.new(key, retry_policy: Chatly::RetryPolicy.new(
  attempts: 5, base_delay: 0.25, max_delay: 10.0
))
```

A retried write **reuses the Idempotency-Key of the attempt that failed**,
which is the whole reason the header exists: without it, a `POST` that landed
upstream before the connection dropped would be written twice by the retry.

## Idempotency

Every write (`POST`, `PUT`, `PATCH`, `DELETE`) carries an `Idempotency-Key`
header. By default each call mints a fresh UUID.

To retry the **same logical operation** — across a crash, a redeploy, a job
replay — pin the key:

```ruby
key = SecureRandom.uuid
pinned = chatly.with_idempotency_key(key)
pinned.contacts.upsert(externalId: "user_42", email: "ada@example.com")
```

Same key + same body replays the first response. Same key + a _different_
body is a `409`, which you can recognise:

```ruby
rescue Chatly::ConflictError => e
  raise unless e.idempotency_conflict?
  # you reused a key with a different body: send the original, or mint a new key
```

`with_idempotency_key` returns a **derived** client; the original is
unchanged. Persist the key alongside the job that does the write and a worker
that dies mid-write cannot double-write when it is replayed.

## Webhook verification

Chatly signs every webhook delivery with the header

```
x-livechat-signature: t=<unix seconds>,v1=<hex>
```

where `v1` is HMAC-SHA256 over the bytes `<t>.<raw body>` — the timestamp
is bound **into** the digest, which is what makes the replay window
enforceable.

```ruby
Chatly.verify_webhook_signature(body, signature_header, secret, tolerance = 300, now: nil)
# => true / false
```

It returns `false` — it never raises — for a malformed header, a missing or
non-numeric `t`, a timestamp outside the tolerance, or a digest that does not
match. A verifier that raised would be an accepted webhook in any handler
that forgot to rescue.

**Pass the raw bytes.** Re-serialising parsed JSON reorders keys and changes
whitespace, and the digest will not match.

### Rails

```ruby
# config/routes.rb
post "/webhooks/chatly", to: "chatly_webhooks#create"

# app/controllers/chatly_webhooks_controller.rb
class ChatlyWebhooksController < ActionController::API
  def create
    verified = Chatly.verify_webhook_signature(
      request.raw_post,                                # NOT `params`
      request.headers["X-LiveChat-Signature"],
      ENV.fetch("CHATLY_WEBHOOK_SECRET")
    )
    return head(:unauthorized) unless verified

    event = JSON.parse(request.raw_post)
    ChatlyEventJob.perform_later(event)                # ack fast, work later
    head :ok
  end
end
```

If the controller has `protect_from_forgery` or a JSON body parser in front of
it, `request.raw_post` is still the bytes as received — that is the point of
using it.

### Rack

```ruby
class ChatlyWebhook
  def call(env)
    request = Rack::Request.new(env)
    body = request.body.read
    request.body.rewind

    ok = Chatly.verify_webhook_signature(
      body,
      env["HTTP_X_LIVECHAT_SIGNATURE"],
      ENV.fetch("CHATLY_WEBHOOK_SECRET")
    )
    return [401, { "content-type" => "text/plain" }, ["invalid signature"]] unless ok

    handle(JSON.parse(body))
    [200, { "content-type" => "text/plain" }, ["ok"]]
  end
end
```

Re-verifying an archived delivery, where the timestamp is long stale:

```ruby
Chatly.verify_webhook_signature(body, header, secret, Float::INFINITY)
```

## Identity verification (widget `userHash`)

When a workspace turns identity verification on, the widget must prove the
`externalId` it claims was issued by your backend rather than typed into a
browser console — otherwise anyone can open a chat as anyone else's account
and read that account's history. This is the backend half of that handshake:

```ruby
user_hash = Chatly.identity_hash(ENV.fetch("CHATLY_IDV_SECRET"), current_user.id)
```

Then, in the page:

```erb
<script>
  Chatly("identify", {
    externalId: "<%= current_user.id %>",
    userHash:   "<%= user_hash %>",
    email:      "<%= current_user.email %>"
  });
</script>
```

The secret is the workspace's identity-verification secret and is a different
credential from the API key. It must never reach a browser — only the digest
does. An empty secret or an empty id raises `ArgumentError`, because HMAC
would otherwise happily return a valid-looking digest from an unset
environment variable and the widget would reject it with no explanation.

## The escape hatch

140 routes accept an API key and 55 have a typed method here. The other 85 are
reachable through `request`, with the same auth, idempotency, retry and error
handling:

```ruby
chatly.request("POST", "/v1/tickets/#{id}/time", nil, { minutes: 30, note: "call" })
chatly.request("GET", "/v1/reports/analytics/csat", { days: 90 })
chatly.request("GET", "/v1/kb/drafts")
```

```ruby
chatly.request(method, path, query = nil, body = nil, idempotency_key: nil, headers: {})
```

Returns the decoded JSON (or `nil` for a `204`) and raises the same typed
errors. `POST`/`PUT`/`PATCH`/`DELETE` get an `Idempotency-Key` automatically.
The full route list is at [chatlychat.com/docs](https://chatlychat.com/docs).

## Injecting a transport

Anything responding to `call(Chatly::Request) -> Chatly::Response` can replace
`net/http` — a pooling HTTP client, a recorder, or a stub in your own tests:

```ruby
class RecordingTransport
  def initialize(inner) = @inner = inner
  def call(request)
    Rails.logger.info("chatly #{request.method} #{request.url}")
    @inner.call(request)
  end
end

Chatly::Client.new(key, transport: RecordingTransport.new(Chatly::NetHttpTransport.new))
```

`Chatly::Request` has `method`, `url`, `headers` (lowercased keys) and `body`
(an encoded JSON String, or `nil`). `Chatly::Response` takes `status:` as an
Integer, `headers:` as a Hash and `body:` as a String. A transport must **not**
raise on a `4xx`/`5xx` — returning the response is what lets this gem type the
error. Anything it does raise is wrapped as `Chatly::TransportError` with the
original available as `#cause`.

The default transport opens a connection per request. That is deliberate:
`Net::HTTP`'s own persistence is not thread-safe, and a pooled connection
shared across threads needs synchronisation this gem does not want to own. If
the handshake shows up in a profile, inject a pooling transport.

## Development

No bundler, no gems, nothing to install — the suite is stdlib `minitest`:

```bash
ruby -Ilib -Itest test/all.rb
```

It runs offline: no network, no API key, no running API. Every HTTP test
either injects a fake transport or stands up a `TCPServer` on `127.0.0.1`
(`test/loopback_test.rb`, which exercises the real `net/http` path — the
request line, the headers and the body as actually written to a socket).

One file at a time:

```bash
ruby -Ilib -Itest test/webhooks_test.rb
```

Running the suite regenerates `surface.lock.json` — the 55 methods, each with
the `METHOD /path` it actually issued, recorded by calling every one of them
and normalising the interpolated segments back to the manifest's `{...}`
names. The test fails if the lock and
[`packages/sdk-spec/surface.json`](../sdk-spec/surface.json) disagree, so
drift shows up as a red test and a dirty working tree rather than as a
`404` in your integration.

## License

MIT. See [LICENSE](LICENSE).

---

## About this repository

This is a **mirror**. `chatly-ruby` is built from a private monorepo where the rest
of the platform, its migrations and its contract checks live, so a pull request here
cannot be merged directly — but a patch is still the fastest way to get something
fixed and we will port it with attribution.

What you can do here: read the source, run the tests, open an issue, or open a PR
and we will treat the diff as the proposal.

Issues: https://github.com/chatlychat/chatly-ruby/issues · Docs: https://chatlychat.com/docs
