# Changelog

All notable changes to the `chatly` gem. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- **`bots.rotate_external_secret(id, activate_at: nil)` can schedule the
  switch.** `activate_at:` takes a `Time` (sent as UTC ISO 8601 with
  milliseconds and a `Z`) or an ISO 8601 String (sent verbatim) and goes up
  as exactly `{"activateAt": "..."}`; the old secret keeps signing until that
  instant. The answer now carries `activatesAt` — `nil` when the new secret
  is already signing. The no-argument call is unchanged on the wire: no body,
  still the hard cut. Any other type raises `ArgumentError` before sending.

- **`Chatly::Page` refuses a body that is not a page envelope.** It used to
  read `raw.is_a?(Hash) ? raw : {}`, so a non-page body became a Page with no
  items and no cursor: `auto_list` over such a route yielded nothing and
  returned normally, which reads as "this workspace is empty". A body with no
  `items` array now raises `Chatly::Error` with `code: "sdk_not_a_page"`. An
  absent, null or empty `nextCursor` is still a valid page — it means this was
  the last one. Two sibling SDKs shipped the silent version of this against
  `GET /v1/macros`, which is `@PaginationExempt`.

### Added

- **The other 107 routes.** The gem covered 55 of the routes in
  `packages/sdk-spec/surface.json`; it now covers all 162, across eleven
  new namespaces — `ai`, `bots`, `bot_routes`, `brands`, `canvas_steps`,
  `customer_cards`, `customer_card_endpoints`, `docs_sources`,
  `email_templates`, `knowledge_gaps`, `triggers` — and new methods on
  `billing`, `channels`, `contacts`, `conversations`, `macros`, `reports`,
  `tickets`, `webhooks` and `workspace`. Every route was verified against its
  handler before being written, rather than against the manifest: the manifest
  has been wrong in both directions before.
- `Chatly::Client#me` (`GET /v1/me`), `webhooks.delete` and
  `workspace.mine`, the three routes added to the manifest on 2026-10-14.
  `me` is the **health check** to prefer: `whoami` needs `workspace:read`
  while `/v1/me` needs no permission at all, so a key with no useful scope
  still gets a truthful `200`. `webhooks.delete` closes an asymmetry — a key
  could register a delivery target and never remove one, so a pipeline that
  registered an endpoint per environment leaked one per run — and it is the
  one delete on this surface that both answers a body (`{ok: true}`, a `200`)
  and `404`s on a miss. `workspace.mine` is a bare `Array` holding exactly one
  entry for a key, which makes it the cheap way to confirm which tenant a key
  points at; it answers on a suspended workspace.
- Three more auto-paginators, for the three genuinely cursored routes among
  the new ones: `bots.auto_list`, `bots.auto_deliveries` and
  `triggers.auto_list`. `bots.deliveries` has a cursor composed of the sort
  value and the row id, so changing `sort:` midway through a walk silently
  restarts at page one — `Pagination` carries the caller's query through
  unchanged, which is what makes the walker safe.
- `test/packaging_test.rb`, because `chatly.gemspec` lists `spec.files`
  explicitly and `lib/chatly.rb` requires every resource by name: one
  forgotten row would make `require "chatly"` raise `LoadError` for every
  customer while the whole suite stayed green. Eleven files were one edit
  away from exactly that. It also asserts every resource class is reachable
  as a client namespace, so a loaded-but-unwired resource cannot read as a
  feature.
- `surface.lock.json` carries a `shape` column — the top-level response shape
  this gem's decoder expects for each of the 162 routes (`array`, `page`,
  `object` or `empty`), declared by hand in `test/surface_lock_test.rb` from
  the handlers and NOT read from `surface.json`, so that
  `scripts/check-sdk-surface-parity.mjs` diffs eight independent columns
  against the manifest. The fake transport now answers each route with a body
  of its own declared shape, and the suite asserts the value handed back
  really has that shape.

### Fixed

- **`billing.usage` could not succeed.** `GET /v1/billing/usage` validates
  `eventType` against a closed four-value list and throws a `400` before
  reading anything, so `chatly.billing.usage` — the obvious call — was always
  an error. It now takes the meter as its first argument and raises
  `ArgumentError` locally when it is missing. `usage_daily` has the same gate;
  `usage_monthly` deliberately does not read the parameter at all.
- Two class comments that argued against the API. `Channels` said channel
  writes "need `channels:write`, which no key-accessible route grants" (the
  scope is grantable and four write routes accept it; what is closed is
  `DELETE` and reading the current secret), and `Webhooks` said registering an
  endpoint was not key-accessible while its own `list` pointed at the delivery
  log — so there was no method for `GET /v1/webhooks` at all and nothing
  obviously missing to notice. The `Reports` header claimed all its routes
  took the same window parameters; seven spellings are now listed, because a
  misspelled window parameter on those routes is silently the default window
  and the report looks plausible.
- The escape-hatch example, twice over. It reached for
  `POST /v1/tickets/{id}/time`, which carries no `@AllowApiKey()` at all — a
  key gets a `403`, so the snippet in the README could never have run — and
  then for `DELETE /v1/webhooks/{id}`, which became a typed method a day
  later. The manifest is now exactly the set of key-accessible routes, so the
  documented uses are a route the API opens next and reaching past a typed
  method with a header it does not surface.

### Documentation

- The pagination table said seven cursor-paginated endpoints and listed seven;
  there are ten (`contacts.journey`, `conversations.unattended` and
  `search.query` were missing, along with their `auto_*` twins).
- `contacts.remove_tag` and `conversations.cancel_scheduled` are `DELETE`s that
  answer `200` with a body; `macros.delete` is the only call on this surface
  that returns `nil`.

## 0.1.0 — 2026-10-12

First release. The official Ruby backend SDK for the Chatly API, implementing
the shared cross-language SDK contract (`packages/sdk-spec/CONTRACT.md`).

### Added

- `Chatly::Client` — 55 methods across 13 namespaces (`contacts`,
  `conversations`, `tickets`, `macros`, `kb`, `search`, `events`, `webhooks`,
  `reports`, `channels`, `billing`, `workspace`, plus `whoami`). Only routes a
  `ck_` workspace key can actually reach are wrapped; a method that always
  returned 403 would be worse than no method.
- `Client#request` — the escape hatch, for the 85 key-accessible routes with no
  typed method. Same auth, idempotency, retries and error typing.
- Typed errors: `Chatly::Error` plus `AuthenticationError` (401),
  `PermissionError` (403), `NotFoundError` (404), `ConflictError` (409, with
  `#idempotency_conflict?`), `ValidationError` (422/400), `RateLimitError`
  (429, with `#retry_after`), `ServerError` (5xx) and `TransportError` (no
  HTTP response at all). Every one carries `status`, `code`, `message`,
  `request_id`, `body` and `details`.
- Retries: connection failures, 429 and 5xx only, three attempts by default,
  exponential backoff with half jitter, `Retry-After` honoured and clamped.
  A retried write reuses the Idempotency-Key of the attempt that failed.
- Idempotency: every write mints a fresh UUID; `Client#with_idempotency_key`
  returns a derived client that pins one across calls.
- Auto-pagination for the seven cursor-paginated endpoints: `auto_list` /
  `auto_messages` / `auto_articles` / `auto_deliveries` return a lazy
  `Enumerator`, so `each`, `lazy` and `first(n)` all work and only the pages
  consumed are fetched. Stops on a null cursor, and stops rather than spinning
  if the server repeats a cursor. `Chatly::Pagination.each_page` walks page
  boundaries.
- `Chatly.verify_webhook_signature` — HMAC-SHA256 over `<t>.<raw body>`,
  constant-time compare, 300-second default tolerance, and `false` rather than
  an exception for every malformed input.
- `Chatly.identity_hash` — the widget `userHash` for identity verification.
- `Chatly::NetHttpTransport`, and an injectable transport interface
  (`call(Chatly::Request) -> Chatly::Response`) so tests need no network.
- Zero runtime dependencies: `net/http`, `json`, `openssl`, `securerandom`,
  `time` and `uri` from the standard library.
- `surface.lock.json` — parity evidence regenerated on every test run by
  calling all 55 methods and recording the request each one issues. The test
  fails if the lock and `packages/sdk-spec/surface.json` disagree.

### Notes

- `conversations.send_message` is `send` in the shared method list. Ruby
  cannot use that name — `send` is `Object#send` — and this is the only
  method whose name differs.
- `contacts.add_tags` sends one tag per call, because the route's body is
  `{"tag": "..."}`. An Array raises `ArgumentError` rather than sending
  something the API would silently drop.
- `macros.list` returns a plain `Array` and has no `auto_list`. Its route is
  `@PaginationExempt` and answers with a bare array capped at 200 rows, so
  there is no cursor to walk and no page to wrap.
