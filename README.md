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

A key reaches only the routes the API opens to one. The rest need a signed-in
person and answer a key with `403` — a reaction records _who_ reacted, and a
key is not a person. This gem wraps every route in the shared SDK manifest
(`packages/sdk-spec/surface.json`), all 163 of them, and nothing a key cannot
use: a method that always fails is worse than no method, because the failure
arrives in production, in somebody else's integration. As of 2026-10-14 that
manifest is exactly the set of routes carrying `@AllowApiKey()`, so there is
nothing a key can reach that has no typed method here — see
[The escape hatch](#the-escape-hatch) for what happens when the API opens the
next one.

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

163 methods across 24 namespaces. `client.<namespace>.<method>`.

Deliberate absences: there is no `contacts.block` or `contacts.unblock`, no
`channels.delete`, no `bots.delete` and no way to read a channel's current
secret. Those routes record _who_ did it, or hand back credential material
with no trace, and they answer a key with `403` or `404`. Where the API offers
a rotation instead of a reveal, the rotation is here.

### Credential

| Ruby     | HTTP                      |
| -------- | ------------------------- |
| `whoami` | `GET /v1/api-keys/whoami` |
| `me`     | `GET /v1/me`              |

Call one of them first. Both return the workspace the key belongs to and the
scopes it was granted, which turns a mis-scoped key into an obvious error at
integration time rather than a `403` from an unrelated endpoint weeks later.

The difference is the permission, and it is why **`me` is the one to use as a
health check**: `whoami` requires `workspace:read`, while `/v1/me` requires
nothing at all — what a key learns there is its own workspace id and its own
grant list, the two things it presented in order to ask. So a key with no
useful scope still gets a `200`, and that answer is true. `me` is
discriminated on `principal` and a `ck_` key gets `"api_key"`; there is no
user behind a key.

Neither says the workspace is healthy — both answer while it is suspended.
`billing.summary` is the one that says whether it can trade, and
`workspace.mine` the one that says which tenant the key points at.

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
| `contacts.cards(id, attrs = {})`       | `POST /v1/contacts/{id}/cards`        |
| `contacts.mood(id, query = {})`        | `GET /v1/contacts/{id}/mood`          |

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

`cards` is a **`POST` that reads your own backend**, not ours: it calls each
configured customer card's URL, signed, and returns what came back under
`cards` (not `items`). The array is always as long as the number of configured
cards and in configuration order; a card that failed arrives as
`state: "error"` with `blocks: nil` rather than being left out. An unknown
contact answers `{"cards" => []}`, not a `404`. Configure the cards with
`client.customer_cards`.

`mood` takes `days:` with a **floor of 7** — `days: 1` is a `400`, where
`journey` on the same resource accepts it. `buckets: []` beside a non-zero
`sampleCount` means "not enough signal", which is an answer and not an error.

### `conversations`

| Ruby                                                 | HTTP                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------ |
| `conversations.list(query = {})`                     | `GET /v1/conversations`                                      |
| `conversations.auto_list(query = {})`                | ↳ auto-paginating `Enumerator`                               |
| `conversations.get(id)`                              | `GET /v1/conversations/{id}`                                 |
| `conversations.messages(id, query = {})`             | `GET /v1/conversations/{id}/messages`                        |
| `conversations.auto_messages(id, query = {})`        | ↳ auto-paginating `Enumerator`                               |
| `conversations.send_message(id, attrs)`              | `POST /v1/conversations/{id}/messages`                       |
| `conversations.unattended(query = {})`               | `GET /v1/conversations/unattended`                           |
| `conversations.auto_unattended(query = {})`          | ↳ auto-paginating `Enumerator`                               |
| `conversations.agent_handling(id)`                   | `GET /v1/conversations/{id}/agent-handling`                  |
| `conversations.set_agent_handling(id, attrs)`        | `PUT /v1/conversations/{id}/agent-handling`                  |
| `conversations.generated_replies(id)`                | `GET /v1/conversations/{id}/generated-replies`               |
| `conversations.generate_reply(id, attrs = {})`       | `POST /v1/conversations/{id}/generated-replies`              |
| `conversations.scheduled_messages(id)`               | `GET /v1/conversations/{id}/scheduled-messages`              |
| `conversations.schedule_message(id, attrs)`          | `POST /v1/conversations/{id}/scheduled-messages`             |
| `conversations.cancel_scheduled(scheduled_id)`       | `DELETE /v1/conversations/scheduled-messages/{scheduled_id}` |
| `conversations.record_outcome(id, attrs)`            | `POST /v1/conversations/{id}/outcomes`                       |
| `conversations.outcomes(id)`                         | `GET /v1/conversations/{id}/outcomes`                        |
| `conversations.return_to_bot(id, bot_id)`            | `POST /v1/conversations/{id}/return-to-bot`                  |
| `conversations.linked(id)`                           | `GET /v1/conversations/{id}/linked`                          |
| `conversations.unread_counts(query = {})`            | `GET /v1/conversations/unread-counts`                        |
| `conversations.update_blocks(id, message_id, attrs)` | `PATCH /v1/conversations/{id}/messages/{message_id}/blocks`  |

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

`record_outcome(id, outcome:)` reports how a conversation ended, in three
words. `resolved` files an AI-resolution row; `escalated` is not a recording
but an **action** — the thread moves to `pending`, bot ownership is released
and your `reason:` is posted to the human as an internal note; `purchased`
writes a CDP event and **requires `outcomeRef:`** (your order id, unique per
workspace forever, which is what makes a retry a no-op). `valueCents:` and
`currency:` are refused on anything but `purchased`, and **nothing in Chatly
sums `valueCents`** — there is no revenue report. `created: false` beside a
`201` means an equal outcome was already on record; that is success.

`return_to_bot(id, bot_id)` hands an open thread back to an assistant after a
human took it. `bot_id` is required and is not defaulted to the previous
owner. Only `open` threads are returnable; `pending`, `snoozed`, `closed` and
`merged` are each a `400`, and a thread the named bot already owns is a
success.

`linked` and `outcomes` both answer an **object carrying `items` with no
cursor** — read `items` yourself; they are not pages.

`unread_counts` is a per-agent badge, and an API key is not an agent:
`mentions` and `participating` are `0` for every key, and `unread` degrades to
"every conversation with a customer message". Use `unattended` for a queue
depth from a key. Its one parameter is spelled `brand:`, not `brandId:`.

`update_blocks(id, message_id, patches:)` edits rich blocks on a message
already delivered — the order card that still says "Processing". A patch's
`id` is a **block** id; an unknown one is a `404` and an invalid merged result
refuses the whole batch.

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
| `tickets.conversations(id)`                 | `GET /v1/tickets/{id}/conversations`                 |
| `tickets.lineage(id)`                       | `GET /v1/tickets/{id}/lineage`                       |
| `tickets.status_history(id)`                | `GET /v1/tickets/{id}/status-history`                |
| `tickets.time(id)`                          | `GET /v1/tickets/{id}/time`                          |
| `tickets.open_count(conversation_id)`       | `GET /v1/tickets/open-count/{conversation_id}`       |

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

The five reads added later **disagree about a missing ticket, deliberately**:
`status_history` and `lineage` answer `404`, `conversations` answers `200` with
an empty `Array`, and `time` answers `200` with zeros _without checking the
ticket exists at all_ — so a zero there means "nothing logged **or** no such
ticket". Do not write one shared not-found path for them.

`status_history` and `time` are objects carrying `items` with no cursor;
`truncated` on the first is what distinguishes a capped timeline from a short
one. `open_count` takes a **conversation** id and is the pre-flight call
before auto-creating a ticket for a chat.

### `macros`

| Ruby                       | HTTP                              |
| -------------------------- | --------------------------------- |
| `macros.list(query = {})`  | `GET /v1/macros`                  |
| `macros.get(id)`           | `GET /v1/macros/{id}`             |
| `macros.create(attrs)`     | `POST /v1/macros`                 |
| `macros.update(id, attrs)` | `PATCH /v1/macros/{id}`           |
| `macros.delete(id)`        | `DELETE /v1/macros/{id}`          |
| `macros.actions`           | `GET /v1/macros/actions`          |
| `macros.templates`         | `GET /v1/macros/templates`        |
| `macros.template(slug)`    | `GET /v1/macros/templates/{slug}` |

A macro is a canned reply plus optional conversation actions. `create`
requires `name:` and `scope:` (`"workspace"`, `"team"` or `"personal"`), plus
reply text, at least one action, or both. `teamId:` is required when `scope:`
is `"team"`.

`list` query: `scope:`, `team:`, `query:`, `language:`. **It returns a plain
`Array`, not a `Chatly::Page`** — this route is not paginated: the API caps it
at 200 rows ordered by usage rank and answers with a bare array. There is no
`macros.auto_list`, because there is no cursor to walk.

A key can never read a **personal** macro: row-level security compares the
caller's user id, and a key's is the key's own. The refusal arrives as a `404`
from `get` and as a row simply not being in `list`.

`actions` and `templates` are **objects**, not arrays — `{"limit", "actions"}`
and `{"items", "total"}` — so `[0]` on either is `nil`. `total` is the whole
count, not a hint at a page two. `template` takes a **slug**. A macro that
references an action the registry no longer has is the one **`422`** most
callers of this API will ever see, from `create` and `update`.

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

### `webhooks` — endpoints and delivery log

| Ruby                                              | HTTP                                          |
| ------------------------------------------------- | --------------------------------------------- |
| `webhooks.list`                                   | `GET /v1/webhooks`                            |
| `webhooks.create(attrs)`                          | `POST /v1/webhooks`                           |
| `webhooks.delete(id)`                             | `DELETE /v1/webhooks/{id}`                    |
| `webhooks.events`                                 | `GET /v1/webhooks/events`                     |
| `webhooks.schema_versions`                        | `GET /v1/webhooks/schema-versions`            |
| `webhooks.set_schema_version(id, schema_version)` | `PATCH /v1/webhooks/{id}/schema-version`      |
| `webhooks.deliveries(query = {})`                 | `GET /v1/webhooks/deliveries`                 |
| `webhooks.auto_deliveries(query = {})`            | ↳ auto-paginating `Enumerator`                |
| `webhooks.delivery(id)`                           | `GET /v1/webhooks/deliveries/{id}`            |
| `webhooks.redeliver(id)`                          | `POST /v1/webhooks/deliveries/{id}/redeliver` |

Registering endpoints **is** key-accessible — this section used to say it was
not, and `list` pointed at the delivery log, so there was no method for
`GET /v1/webhooks` at all and nothing obviously missing to notice.

```ruby
hook = chatly.webhooks.create(url: "https://example.com/hooks/chatly",
                              eventTypes: ["conversation.created", "message.created"])
hook["secret"] # => "whsec_…" — the only time any route returns it
```

**The field is `eventTypes`, not `events`**, and it is checked against the
closed list `webhooks.events` returns — an unknown name is a `400`. The
`secret` comes back from `create` and from nowhere else: there is no reveal
route and no rotation route, so losing it means `delete` and another
`create`.

`delete` answers `{"ok" => true}` with a `200`, and unlike most deletes on
this surface it really does `404` on a miss. It was opened to keys on
2026-10-14 for the reason `create` already made: a key that can **add** a
delivery target and not remove one can only ever add, so a deploy pipeline
registering an endpoint per environment leaked one into the workspace on every
run. The workaround people were told to use — repoint the endpoint at a dead
URL — leaves the subscription alive and the delivery log filling with
failures. The delivery history survives the endpoint; what you remove is the
subscription, not the record.

`set_schema_version` wants the body field `schemaVersion` — note
`schema_versions` calls the same thing `versions[].version`, and the two are
not interchangeable. Moving a pin backward is legal and stops deliveries of
the newer event types; either direction takes effect on the next event.
`isDeprecated` on a version is advisory, and nothing refuses a deprecated pin.

The delivery half is the **history**. `redeliver` queues the recorded payload
against the endpoint's current URL and the outcome appears as a _new_ attempt
in the list. To verify an inbound delivery, see
[Webhook verification](#webhook-verification) — that needs no client.

### `reports`

| Ruby                                       | HTTP                                        |
| ------------------------------------------ | ------------------------------------------- |
| `reports.overview(query = {})`             | `GET /v1/reports/overview`                  |
| `reports.agents(query = {})`               | `GET /v1/reports/agents`                    |
| `reports.conversations_by_day(query = {})` | `GET /v1/reports/conversations-by-day`      |
| `reports.sla(query = {})`                  | `GET /v1/reports/sla`                       |
| `reports.attribution(query = {})`          | `GET /v1/reports/attribution`               |
| `reports.cohorts(query = {})`              | `GET /v1/reports/cohorts`                   |
| `reports.response_times(query = {})`       | `GET /v1/reports/response-times`            |
| `reports.sources(query = {})`              | `GET /v1/reports/sources`                   |
| `reports.teams(query = {})`                | `GET /v1/reports/teams`                     |
| `reports.labels(query = {})`               | `GET /v1/reports/labels`                    |
| `reports.themes(query = {})`               | `GET /v1/reports/themes`                    |
| `reports.theme_conversations(id)`          | `GET /v1/reports/themes/{id}/conversations` |
| `reports.voice(query = {})`                | `GET /v1/reports/voice`                     |

Rollups, not lists — no cursor on any of them. And **the window is not spelled
the same way twice**, which this section used to claim it was:

| Route                                               | Window                                                      |
| --------------------------------------------------- | ----------------------------------------------------------- |
| `overview`, `agents`, `conversations_by_day`, `sla` | `days:` / `from:` / `to:`                                   |
| `attribution`                                       | `dimension:`, `days:` (1–90, default 30)                    |
| `response_times`                                    | `days:` (1–90, default 30)                                  |
| `sources`                                           | `days:` (1–90, default **7**)                               |
| `voice`                                             | `days:` (1–365, default 30)                                 |
| `cohorts`                                           | `weeks:` (2–26, default 8) — **no `days:` at all**          |
| `themes`                                            | `date:` — one batch date, not a range                       |
| `theme_conversations`                               | nothing                                                     |
| `teams`, `labels`                                   | `days:` / `from:` / `to:` / `group_by:` / `business_hours:` |

No reports route validates its query with a schema, so **a misspelled window
parameter is silently the default window** and the report comes back looking
plausible. `group_by` and `business_hours` are snake_case on the wire — this
gem sends query keys exactly as you write them, so `groupBy:` is not a
parameter the API reads. `days`/`weeks` are clamped silently; an explicit
`from`/`to` pair is rejected rather than clamped (both required together,
`to <= from` a `400`, an over-long span a `400`).

`business_hours: true` opts duration metrics into opening hours; the figures
are **never zeroed or relabelled when it could not be applied**, so read
`businessHours["applied"]` before captioning them.

Four of the thirteen are bare `Array`s (`agents`, `conversations_by_day`,
`attribution`, `sources`); the rest are objects. `attribution` can return two
rows with `value: nil` — the untagged bucket and the folded tail — and `label`
is the discriminator. `cohorts` echoes the `weeks` it actually used. `themes`
takes an unvalidated `date:` that reaches Postgres raw, so validate it
yourself or a typo is a `500`.

### `channels`

| Ruby                         | HTTP                                   |
| ---------------------------- | -------------------------------------- |
| `channels.list`              | `GET /v1/channels`                     |
| `channels.get(id)`           | `GET /v1/channels/{id}`                |
| `channels.adapters`          | `GET /v1/channels/adapters`            |
| `channels.create(attrs)`     | `POST /v1/channels`                    |
| `channels.update(id, attrs)` | `PATCH /v1/channels/{id}`              |
| `channels.rotate_secret(id)` | `POST /v1/channels/{id}/secret/rotate` |

A widget can be stood up entirely from code: create the channel, read
`embed["snippet"]`, set the allowed origins, rotate the identity-verification
secret. This section used to say channel writes needed a permission no key is
granted — that was wrong in both halves. What is genuinely closed is
`DELETE /v1/channels/{id}` and reading a channel's current secret;
`rotate_secret` is open _instead_ of the reveal, so you can always get a
working secret and never see the current one. It is `type: "api"` channels
only — anything else is a `409`.

On a web channel, read `originsRestricted` — an **empty** allowed-origins list
means "any origin", which is invisible in the raw JSON.

**Credential-bearing `config` keys come back as the literal string
`"__redacted__"`, on writes as well as reads**, and echoing that value back in
a later `update` means "leave this one alone". A helper that strips or
rewrites the marker destroys credentials. `update` merges `config` per RFC
7396 — a `nil` value deletes that key — unless you pass
`configMode: "replace"`; a body with no recognised field is a `409`, not a
no-op.

### `billing`

| Ruby                                          | HTTP                            |
| --------------------------------------------- | ------------------------------- |
| `billing.plans`                               | `GET /v1/billing/plans`         |
| `billing.summary`                             | `GET /v1/billing`               |
| `billing.usage(event_type, range = {})`       | `GET /v1/billing/usage`         |
| `billing.usage_daily(event_type, range = {})` | `GET /v1/billing/usage/daily`   |
| `billing.usage_monthly(query = {})`           | `GET /v1/billing/usage/monthly` |
| `billing.invoices(query = {})`                | `GET /v1/billing/invoices`      |

Reads only: nothing here starts, changes or cancels a subscription. `usage` is
the call to make before a bulk import, so you find the plan ceiling before the
import does.

**`usage` and `usage_daily` require an `eventType`** — one of
`conversation.opened`, `message.sent.agent`, `message.sent.bot`, `ai.tokens` —
and the API throws a `400` before reading anything without one. This gem takes
it as the first argument and raises `ArgumentError` if it is missing, because
`chatly.billing.usage` with no argument was a method that could never succeed
(four sibling SDKs shipped it that way):

```ruby
chatly.billing.usage("message.sent.agent")
chatly.billing.usage_daily("ai.tokens", from: "2026-10-01T00:00:00Z")
```

`usage_monthly` is the asymmetry worth knowing: it does **not** read
`eventType` at all and always rolls up all four meters, so passing one is
neither an error nor a filter. Its parameter is `month:` as `YYYY-MM`.

`invoices` is cursor-paginated and spells the envelope **`data`**, not
`items` — the only route on this surface that does — so it is a plain `Hash`
here with no `auto_invoices`: a walker keyed on `items` would report an empty
page forever. Pass the `nextCursor` you were given back as `cursor:`. An
unparsable cursor is silently the first page.

### `workspace`

| Ruby                              | HTTP                         |
| --------------------------------- | ---------------------------- |
| `workspace.settings`              | `GET /v1/workspace/settings` |
| `workspace.labels`                | `GET /v1/labels`             |
| `workspace.inboxes`               | `GET /v1/inboxes`            |
| `workspace.team_members(team_id)` | `GET /v1/teams/{id}/members` |
| `workspace.agent_skills`          | `GET /v1/agents/skills`      |
| `workspace.key_scopes`            | `GET /v1/api-keys/scopes`    |
| `workspace.mine`                  | `GET /v1/workspaces/me`      |
| `workspace.secrets`               | `GET /v1/workspace/secrets`  |

Grouped by what they answer — "what is configured in this workspace?" — not
by URL prefix. All reads; creating a label, an inbox or a team is not
key-accessible.

`team_members` takes a **team** id, which comes from the team's dashboard
URL or from a `teamId` on an object you already hold — a macro with
`scope: "team"` carries one.

`agent_skills` returns `{"skills": [...]}` — the distinct skill labels
skill-based routing matches on. An empty array is a normal state for a
workspace that has not set any up, not an error. There is no key-accessible
way to list the people holding a seat: `GET /v1/agents` has no handler.

`mine` answers "which tenant is this key for?" — a bare `Array` holding
exactly **one** entry for a key, because the route is the cross-workspace list
and a key belongs to one workspace. It stays an `Array` in that case: the
shape is set by a person's answer, and a key does not get its own schema.
`role` is the synthetic `restricted` every key is given, not a stored
membership role — what a key may do is its scope set, which `me` answers. Like
`me`, it answers while the workspace is suspended, because it is how a caller
discovers the others.

`key_scopes` is every scope a key may be **granted**, and it is deliberately
narrower than the product's full permission set. `POST /v1/api-keys` validates
scopes as a bare string array, so a key can be created with a name that never
appears here and then be refused by everything.

`secrets` is a census of every credential the workspace holds — existence,
location and timestamps, never a value. It carries `items` with no cursor and
cannot become a page (the rows come from nine tables whose ids are a mix of
UUID v4 and v7, so there is no orderable key across them). Read `truncated`
before concluding a credential does not exist, and read
`rotatedAtBasis` / `lastUsedBasis` before acting on a `nil` timestamp:
`"none"` means nothing in the product records that fact, not that the
credential was never rotated or used. It needs **both** `workspace:write` and
`integrations:read`.

### `ai` — providers, tone and tools

| Ruby                            | HTTP                                    |
| ------------------------------- | --------------------------------------- |
| `ai.providers`                  | `GET /v1/ai-providers`                  |
| `ai.add_provider(attrs)`        | `POST /v1/ai-providers`                 |
| `ai.test_provider(provider)`    | `POST /v1/ai-providers/{provider}/test` |
| `ai.quota`                      | `GET /v1/ai/quota`                      |
| `ai.tone`                       | `GET /v1/ai/tone`                       |
| `ai.set_tone(rules)`            | `PUT /v1/ai/tone`                       |
| `ai.generate_tone(style_guide)` | `POST /v1/ai/tone/generate`             |
| `ai.tone_preview`               | `GET /v1/ai/tone/preview`               |
| `ai.tools`                      | `GET /v1/ai/tools`                      |
| `ai.create_tool(attrs)`         | `POST /v1/ai/tools`                     |
| `ai.update_tool(id, attrs)`     | `PATCH /v1/ai/tools/{id}`               |
| `ai.delete_tool(id)`            | `DELETE /v1/ai/tools/{id}`              |

```ruby
chatly.ai.add_provider(provider: "openai", apiKey: ENV.fetch("OPENAI_KEY"))
chatly.ai.set_tone([{ category: "warmth", rule: "Never blame the customer" }])
```

`providers` is an **object** (`{"providers" => [...]}`) and the array is a
constant three rows — every supported provider, configured or not — so read
`configured` per row rather than counting. A stored key is never returned,
only a four-character `keyHint`.

`add_provider` wants `apiKey:` (not `key:` or `token:`), and **a `201` does
not mean the key works**: a key the provider rejects is a `422`, but one we
could not get an answer about is stored as `unverified`. Read
`validation["status"]`.

`set_tone` is a whole-set replace — `[]` wipes every rule — and it answers
with the same **bare `Array`** the `GET` does, re-read after the write.
`generate_tone` saves nothing and may name a sixth category the `PUT` will
then refuse; that is the design. `quota` returns `nil` budgets on an uncapped
plan, and `spent` bounds only platform spend, never BYOK.

`delete_tool` is a soft delete that answers `{"deleted" => true}` — and
**never `404`s**, for any id, in any workspace. It is not a way to find out
whether a tool existed.

### `bots`

| Ruby                                                | HTTP                                           |
| --------------------------------------------------- | ---------------------------------------------- |
| `bots.list(query = {})`                             | `GET /v1/bots`                                 |
| `bots.auto_list(query = {})`                        | ↳ auto-paginating `Enumerator`                 |
| `bots.get(id)`                                      | `GET /v1/bots/{id}`                            |
| `bots.create(attrs)`                                | `POST /v1/bots`                                |
| `bots.update(id, attrs)`                            | `PATCH /v1/bots/{id}`                          |
| `bots.update_external(id, attrs)`                   | `PATCH /v1/bots/{id}/external`                 |
| `bots.rotate_external_secret(id, activate_at: nil)` | `POST /v1/bots/{id}/external/rotate-secret`    |
| `bots.deliveries(id, query = {})`                   | `GET /v1/bots/{id}/deliveries`                 |
| `bots.auto_deliveries(id, query = {})`              | ↳ auto-paginating `Enumerator`                 |
| `bots.delivery(id, delivery_id)`                    | `GET /v1/bots/{id}/deliveries/{delivery_id}`   |
| `bots.redeliver(id, delivery_id)`                   | `POST /v1/bots/{id}/deliveries/{id}/redeliver` |
| `bots.test_delivery(id)`                            | `POST /v1/bots/{id}/test-delivery`             |
| `bots.analytics(id, query = {})`                    | `GET /v1/bots/{id}/analytics`                  |

Two kinds of bot share these routes: a **Chatly persona** (`type: "chatly"` —
a prompt, tools and a KB scope our AI service runs) and an **external agent**
(`type: "external"` — your service, which we sign a payload and POST to).
Routes that only fit one refuse rather than no-op: `deliveries` is a `404` on
a persona, `update_external` and `rotate_external_secret` are a `400`.

`create` is a union discriminated by `type:` and **neither half is strict**, so
a field from the wrong one is dropped silently. The external branch returns a
`signingSecret` and a `token` **once**, and it de-duplicates a slug collision
instead of answering `409` — always read `slug` off the response.

`test_delivery` signs a rehearsal payload with the real secret, POSTs it to
the real URL **synchronously**, and returns `signature` and `payload` so you
can check a verifier offline. It writes nothing, so it never shows up under
`deliveries`.

`rotate_external_secret(id)` with no `activate_at:` is a **hard cut**: no body
goes up, the answer's `activatesAt` is `nil`, and the old secret stops signing
the moment it returns — deploy first, rotate second. Pass
`activate_at:` (a `Time`, sent as UTC ISO 8601 with a `Z`, or an ISO 8601
String with a `Z` or offset, sent verbatim) for an **overlap window**: the old
secret keeps signing every delivery until that instant, and `activatesAt` in
the answer says when the switch happens. Each delivery carries ONE signature,
so have your verifier accept both secrets for the window. More than 168 hours
ahead (by the server's clock) is a `400`; an instant already past, or an agent
with no usable secret today, is a hard cut and answers `activatesAt: nil`.

`analytics` takes `days:` only (1–365): `from`, `to`, `weeks` and `date` are
**refused by name**. A `nil` rate means its denominator was 0, and a `nil`
count means that kind of bot cannot produce the number. Null is never zero
here.

### `bot_routes`

| Ruby                             | HTTP                          |
| -------------------------------- | ----------------------------- |
| `bot_routes.list`                | `GET /v1/bot-routes`          |
| `bot_routes.fields`              | `GET /v1/bot-routes/fields`   |
| `bot_routes.create(attrs)`       | `POST /v1/bot-routes`         |
| `bot_routes.update(id, attrs)`   | `PATCH /v1/bot-routes/{id}`   |
| `bot_routes.resolve(attrs = {})` | `POST /v1/bot-routes/resolve` |
| `bot_routes.delete(id)`          | `DELETE /v1/bot-routes/{id}`  |

`list` is a bare `Array` in **evaluation order** — first match wins — and it
includes disabled routes. `fields` is the closed condition vocabulary, and
reading it is cheaper than guessing: an unknown field name is a `400`. Its
`prefixes` half is security-relevant — `context.verified.*` is covered by your
signature, while `context.unverified.*` and `contact.attributes.*` are
visitor-writable.

```ruby
chatly.bot_routes.resolve(page: { path: "/pricing" }, contact: { identityVerified: true })
```

`resolve` is a dry run, writes nothing, and **is the production decision**
rather than an approximation of it. It answers `{selected, routes, event}`;
disabled routes are dropped from `routes` entirely, and `event` is where you
see that a field path resolved to nothing. Its body is strict, so a misspelled
key is a `400` — unusual and welcome on this API.

### `brands`

| Ruby                       | HTTP                     |
| -------------------------- | ------------------------ |
| `brands.list`              | `GET /v1/brands`         |
| `brands.create(attrs)`     | `POST /v1/brands`        |
| `brands.update(id, attrs)` | `PATCH /v1/brands/{id}`  |
| `brands.delete(id)`        | `DELETE /v1/brands/{id}` |

`name:` and `slug:` are required. `logoUrl`, `primaryColor`, `supportEmail`,
`replyDomain` and `icons` are flat in the request although they are stored
inside a `branding` object. `isDefault: true` demotes every other brand.
`icons` merges per icon while everything else replaces. `delete` is a soft
delete answering `{"id" => …}`, refused with a `409` for the default brand or
one a channel still points at — which is what the `usage` counts on a `list`
row are for.

### `canvas_steps`

| Ruby                              | HTTP                                 |
| --------------------------------- | ------------------------------------ |
| `canvas_steps.get(id)`            | `GET /v1/canvas-steps/{id}`          |
| `canvas_steps.resolve(id, attrs)` | `POST /v1/canvas-steps/{id}/resolve` |

The back half of an **async canvas step**: your canvas endpoint answered
`{"pending": true}` because a payment needed 3-D Secure, and these are what
the backend job does with the correlation id minutes later. `get` carries
status and expiry, never a canvas. `resolve` takes `canvas:` (strict) and is
**single-use by construction** — the claiming update filters on `pending`, so
exactly one resolve wins and a second is told so with a `409`. That is why the
route honours an `Idempotency-Key` without demanding one. A step lapses after
ten minutes.

### `customer_cards`

| Ruby                               | HTTP                                         |
| ---------------------------------- | -------------------------------------------- |
| `customer_cards.list`              | `GET /v1/customer-cards`                     |
| `customer_cards.create(attrs)`     | `POST /v1/customer-cards`                    |
| `customer_cards.update(id, attrs)` | `PATCH /v1/customer-cards/{id}`              |
| `customer_cards.rotate_secret(id)` | `POST /v1/customer-cards/{id}/rotate-secret` |
| `customer_cards.delete(id)`        | `DELETE /v1/customer-cards/{id}`             |

A card is a key, a title, a URL and a TTL; we call the URL, signed, and render
what comes back beside the conversation. `client.contacts.cards` is the read
of the rendered result.

`create` requires `ttlSeconds:` (15–31,536,000, rejected out of range rather
than clamped) and is strict, so a typo is a `400`. **`secret` sits beside
`card` in the response, not inside it**, and that is the only response
carrying it. At most 25 cards, at most 10 headers; header _values_ are never
returned, only names. `headers: {}` clears the bag.

`rotate_secret` kills the old secret **immediately** — update your verifier
first. Patching `key:` to one another card owns is a `500` rather than the
`409` `create` gives you, so pick a new key instead of moving one.

### `customer_card_endpoints`

| Ruby                                          | HTTP                                                    |
| --------------------------------------------- | ------------------------------------------------------- |
| `customer_card_endpoints.list`                | `GET /v1/customer-card-endpoints`                       |
| `customer_card_endpoints.create(url)`         | `POST /v1/customer-card-endpoints`                      |
| `customer_card_endpoints.rotate_secret(id)`   | `POST /v1/customer-card-endpoints/{id}/rotate-secret`   |
| `customer_card_endpoints.activate_secret(id)` | `POST /v1/customer-card-endpoints/{id}/activate-secret` |
| `customer_card_endpoints.delete(id)`          | `DELETE /v1/customer-card-endpoints/{id}`               |

One signing secret per card **URL** instead of one per card. A single card
request carries several cards (we batch by URL), so without this a receiver
had to hold N secrets and select by `x-chatly-card-id` — a header that changes
with our cache. With an endpoint secret there is one secret, and no
`x-chatly-card-id` on the wire at all. The per-card secret stays as the
documented fallback, so existing receivers keep verifying.

`create` flips signing for that URL the moment it returns — **deploy the
secret first**. The URL is compared byte for byte against your cards' URLs
(trailing slash included); one no card uses is a `400` listing the ones that
do, and one that already has an endpoint is a `409`.

Rotation here is **two-phase**, unlike every other rotation in this gem:
`rotate_secret` mints the next secret with `active: false` and it signs
nothing until `activate_secret`. Mint, deploy, activate. Calling
`rotate_secret` twice replaces the pending secret; `activate_secret` twice is
a `409`. Card secrets are `cc_`, endpoint secrets `cce_`.

### `docs_sources`

| Ruby                                | HTTP                                 |
| ----------------------------------- | ------------------------------------ |
| `docs_sources.providers`            | `GET /v1/docs-sources/providers`     |
| `docs_sources.list`                 | `GET /v1/docs-sources`               |
| `docs_sources.discover(attrs)`      | `POST /v1/docs-sources/discover`     |
| `docs_sources.create(attrs)`        | `POST /v1/docs-sources`              |
| `docs_sources.update(id, attrs)`    | `PATCH /v1/docs-sources/{id}`        |
| `docs_sources.sync(id, attrs = {})` | `POST /v1/docs-sources/{id}/sync`    |
| `docs_sources.webhook(id)`          | `POST /v1/docs-sources/{id}/webhook` |
| `docs_sources.delete(id)`           | `DELETE /v1/docs-sources/{id}`       |

Index somebody else's documentation into the knowledge base. The connect flow
is three calls: `providers` to render a form, `discover` to list the spaces a
credential can see, then `create` with one of them.

```ruby
spaces = chatly.docs_sources.discover(provider: "gitbook", token: tok)
chatly.docs_sources.create(provider: "gitbook", token: tok,
                           organizationId: spaces[0]["organizationId"],
                           spaceId: spaces[0]["id"], publishOnSync: true)
```

The field names are the trap: `organizationId` (not `orgId`), `spaceId` (not
`space`), `publishOnSync` (not `publish`), `syncIntervalMinutes` (not
`interval`), `full` (not `force`). `create` enqueues the first sync before
returning, so its response always reads `syncStatus: "queued"` with
`articleCount: 0` — **read `syncStatus`, never `articleCount`**:
`synced_empty` and `synced_partial` are successes that need a human.

`sync` without `full: true` is a delta, which after a fix on _our_ side finds
nothing upstream and leaves the KB exactly as wrong as it was. A `201` from it
does not prove the source exists — there is no `404` on that route.

`webhook` is a **subscribe, not a receiver**: it asks the provider to push
change events to us. `subscribed: false` with a `reason` is a success — a
read-only token cannot manage webhooks, and the source keeps polling. `delete`
**keeps the articles** and tells you how many in `kept`.

### `email_templates`

| Ruby                                  | HTTP                                |
| ------------------------------------- | ----------------------------------- |
| `email_templates.list`                | `GET /v1/email-templates`           |
| `email_templates.update(kind, attrs)` | `PUT /v1/email-templates/{kind}`    |
| `email_templates.delete(kind)`        | `DELETE /v1/email-templates/{kind}` |
| `email_templates.preview(attrs)`      | `POST /v1/email-templates/preview`  |

Five overridable transactional emails, addressed by `kind` in the path — an
unknown kind is a `400`, not a `404`. `list` is the **catalogue**: always five
entries, with `override` `nil` where the workspace is on the built-in.

`update` is strict and holds only `{subject, body}` — `kind` in the body is a
`400`. `preview` wants it the other way round, with `kind` as a body field;
that mirror image is the trap between the two. `delete` answers
`{"restored" => bool}`, and `false` means there was nothing to remove, which
is success. Restoring follows the built-in copy as it is **today**, not a
snapshot.

`preview`'s `unknownTokens` is how you catch a typo'd `{{token}}` before
sending: the renderer leaves an unknown token visible in real mail.

### `knowledge_gaps`

| Ruby                                | HTTP                                 |
| ----------------------------------- | ------------------------------------ |
| `knowledge_gaps.list(query = {})`   | `GET /v1/knowledge-gaps`             |
| `knowledge_gaps.update(id, status)` | `PATCH /v1/knowledge-gaps/{id}`      |
| `knowledge_gaps.draft(id)`          | `POST /v1/knowledge-gaps/{id}/draft` |

Questions the KB could not answer, most-asked first, as a bare `Array`.
Neither query parameter is strict: an unrecognised `status:` is **silently
ignored** (you get the unfiltered list) and `limit:` is clamped 1–200. There
is no cursor because the recorder caps a workspace at 200 open gaps.

`status` is the only mutable field: `"open"`, `"drafted"`, `"resolved"`,
`"dismissed"`.

`draft` has the model write the missing article. **A `201` can mean "nothing
worth writing"** — `articleId: nil` with a `reason` — and on success the
article is a `draft` with no author and the gap moves to `drafted`, not
`resolved`. It calls an LLM, so raise the client timeout for it.

### `triggers`

| Ruby                             | HTTP                           |
| -------------------------------- | ------------------------------ |
| `triggers.list(query = {})`      | `GET /v1/triggers`             |
| `triggers.auto_list(query = {})` | ↳ auto-paginating `Enumerator` |
| `triggers.create(attrs)`         | `POST /v1/triggers`            |
| `triggers.delete(id)`            | `DELETE /v1/triggers/{id}`     |

```ruby
chatly.triggers.create(name: "Greet pricing visitors",
                       eventType: "conversation.created",
                       enabled: true, conditions: [],
                       actions: [{ type: "send_message", params: { body: "Questions?" } }])
```

`create` is an **upsert** — passing `id:` updates, and both branches answer
`201`. `enabled:` and `conditions:` are required keys even though
`conditions: []` is legal, and `actions:` needs at least one entry.

**`eventType` is a free string and is not checked against the catalogue of
events that have a publisher**, so a typo saves successfully and produces a
rule that never fires. That is the expensive mistake here and the only one the
API will not tell you about.

`list` has no trigger-specific filters — narrow through `filter:` — and
`sort:`/`fields:` are validated strictly while any other unknown query key is
dropped. `delete` is a hard delete answering `{"ok" => true}`; a miss is a
`404`, never `ok: false`.

### `visitors`

| Ruby                              | HTTP                                               |
| --------------------------------- | -------------------------------------------------- |
| `visitors.start_conversation(id)` | `POST /v1/visitors/{contactId}/start-conversation` |

```ruby
chatly.visitors.start_conversation(contact_id)["conversationId"]
```

Opens a thread with a contact who did **not** write first and sends the
workspace's proactive greeting into it. The contact id is the whole input —
no body, no query — and the answer is `{"conversationId" => "…"}`.

**It is off by default, per workspace, and that is the commonest `403`.** The
flag is `settings.proactiveOutreach.apiKeysMayStartConversations`; an owner or
admin turns it on with `PATCH /v1/workspace/settings`, which needs a signed-in
person and is not in this gem, and you can read the current value with
`client.workspace.settings`, which is. The scope is **not** the opt-in:
`conversations:write` was already grantable and is already held by keys minted
for ticket bulk actions and schedule-send, so a `Chatly::PermissionError` here
usually means the setting rather than your scopes. Check it first.

**Three per contact per hour**, counted per workspace and per _contact_ rather
than per caller — the abuse shape is N threads at one person. The fourth call
inside the hour raises `Chatly::RateLimitError`.

Two different `429`s come off this route and they do not look alike. The
per-contact limit sends **no `Retry-After` header** — the wait is only in the
body, at `error.details.retryAfterSeconds` — while the global throttler
buckets the route inherits (`short`, 30/s; `login`, 100/15min) do send one.
`#retry_after` is set in both cases because this gem falls back to the body
field, which is exactly why you should read `#retry_after` and not the header.

**An offline visitor is not notified**: the greeting is persisted and the
widget renders it from history on their next page view, with no email, push or
provider message. To reach someone who has left the site, use an email or SMS
conversation instead.

`GET /v1/visitors/live` and `GET /v1/visitors/{contactId}/pages` sit on the
same controller and are **not** here — neither carries `@AllowApiKey()`, so a
key gets a `403` from both.

## Pagination

Thirteen endpoints are cursor-paginated, and each returns
`{ "items": [...], "nextCursor": "…" | null }` — with whatever the route puts
beside them. For each you get both the single page and an auto-paginating
`Enumerator`:

| Page                         | Enumerator                        |
| ---------------------------- | --------------------------------- |
| `bots.list`                  | `bots.auto_list`                  |
| `bots.deliveries(id)`        | `bots.auto_deliveries(id)`        |
| `contacts.list`              | `contacts.auto_list`              |
| `contacts.journey(id)`       | `contacts.auto_journey(id)`       |
| `conversations.list`         | `conversations.auto_list`         |
| `conversations.messages(id)` | `conversations.auto_messages(id)` |
| `conversations.unattended`   | `conversations.auto_unattended`   |
| `tickets.list`               | `tickets.auto_list`               |
| `kb.articles`                | `kb.auto_articles`                |
| `search.query(q)`            | `search.auto_query(q)`            |
| `events.list`                | `events.auto_list`                |
| `triggers.list`              | `triggers.auto_list`              |
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

Every route in the shared SDK manifest has a typed method here, and as of
2026-10-14 that manifest is exactly the set of routes carrying
`@AllowApiKey()` — so there is no key-accessible route left for `request` to
reach. It is here for the two cases that outlive that snapshot, with the same
auth, idempotency, retry and error handling:

```ruby
# 1. A route the API opens NEXT. Not hypothetical: `DELETE /v1/webhooks/{id}`
#    spent a day key-accessible and unlisted, and `webhooks.delete` landed
#    after the manifest did.
chatly.request("DELETE", "/v1/webhooks/#{id}")

# 2. Reaching past a typed method — a header, query parameter or body field
#    this gem does not surface yet.
chatly.request("POST", "/v1/contacts/bulk", nil, { contacts: rows },
               headers: { "X-Chatly-Trace" => "import-4812" })
```

**It does not get you into a route a key cannot use.** Those answer `403`, and
no amount of escape hatch changes that: `POST /v1/tickets/{id}/time` carries
no `@AllowApiKey()`, and this README used it as the worked example here for a
year.

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

Running the suite regenerates `surface.lock.json` — the 163 methods, each with
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
