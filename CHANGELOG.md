# Changelog

All notable changes to the `chatly` gem. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Auto-pagination: `auto_list` / `auto_messages` / `auto_articles` /
  `auto_deliveries` return a lazy `Enumerator`, so `each`, `lazy` and
  `first(n)` all work and only the pages consumed are fetched. Stops on a null
  cursor, and stops rather than spinning if the server repeats a cursor.
  `Chatly::Pagination.each_page` walks page boundaries.
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
- `macros.list` is marked paged in the shared spec and is not paged by the
  API; it returns a bare array capped at 200 rows, which this gem presents as
  a single cursorless `Chatly::Page`.
