# Charybdis test plan

**Package:** `services/appview-worker`  
**Shared library:** `packages/swift/ThinAppViewCore`  
**CI:** `charybdis`

The source directory, executable product, and `appview-worker` telemetry identity remain stable while Railway names the deployed service Charybdis.

## Commands

```bash
# Shared core (tested first in the CI job)
cd packages/swift/ThinAppViewCore
swift test

# Worker CLI + wiring
cd services/appview-worker
swift test
swift build   # compile check
```

## Test layout

```
services/appview-worker/Tests/AppViewWorkerTests/
  AppViewWorkerSmokeTests.swift

packages/swift/ThinAppViewCore/Tests/ThinAppViewCoreTests/
  ThinAppViewIndexerTests.swift
  AppViewProjectionCacheTests.swift
  …
  Fixtures/                  # static commit JSON (no live firehose)
```

## ThinAppViewCore

The worker executable delegates to `ThinAppViewWorkerRuntime` from ThinAppViewCore. Core tests cover:

- `RenderFieldExtractor` — publication/entry field extraction
- `SQLiteThinAppViewStore` — indexing, unread filtering
- `ThinAppViewIndexer` — fixture commit → `IndexedContentItem`
- retired Tap compatibility, repository restoration, and Jetstream cursor policies
- Skyreader RSS parsing, stable identity, ingestion, and polling
- `AppViewProjectionCacheStore` — sidebar/unread snapshot caches
- `ThinAppViewQuerySupport` — pagination SQL

Postgres store tests are integration-level. SQLite remains covered directly in
package tests, but the current Charybdis entry point rejects `APP_ENV=local`
through its shared Operations environment guard. Runnable service integration
uses `APP_ENV=dev` with an isolated disposable Postgres database.

## Worker tests

- CLI argument parsing (`AppViewWorkerCommand`)
- Env loading for `ENABLE_THIN_APPVIEW`, relay URL, TTL vars, proactive backfill
- Runtime bootstrap with in-memory SQLite (no network)

## Manual verification (ingestion)

The worker has no HTTP surface. Verify via gateway/AppView routes:

1. Apply migrations to an isolated disposable Postgres database, then start AppView and Charybdis with the same `DATABASE_URL` (see the root README).
2. Enroll `authorDids` and/or `feedUrls` with `app.thesocialwire.appview.enrollSources` (or its `/v1/appview/enroll` compatibility route), then leave Charybdis running for Jetstream V1/V2 and RSS poll ingestion.
3. Use Bruno `services/gateway/bruno/AppView/` or `services/appview/bruno/` to confirm timeline rows appear.

## Related

- [AppView test plan](./appview.md)
- [Thin AppView architecture](../architecture/appview.md)
