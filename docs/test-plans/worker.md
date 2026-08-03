# Charybdis test plan

**Package:** `services/appview-worker`  
**Shared library:** `packages/swift/ThinAppViewCore`  
**CI:** `test-appview-worker`

The legacy package path, executable product, CI key, Fly app names, and `appview-worker` telemetry identity remain stable for compatibility.

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
- Tap consumers/repository restoration and Jetstream cursor policies
- Skyreader RSS parsing, stable identity, ingestion, and polling
- `AppViewProjectionCacheStore` — sidebar/unread snapshot caches
- `ThinAppViewQuerySupport` — pagination SQL

Postgres store tests are integration-level; local dev uses SQLite via `APP_ENV=local`.

## Worker tests

- CLI argument parsing (`AppViewWorkerCommand`)
- Env loading for `ENABLE_THIN_APPVIEW`, relay URL, TTL vars, proactive backfill
- Runtime bootstrap with in-memory SQLite (no network)

## Manual verification (ingestion)

The worker has no HTTP surface. Verify via gateway/AppView routes:

1. Start AppView and Charybdis with the same absolute `SQLITE_DB_PATH` (see the root README).
2. Enroll `authorDids` and/or `feedUrls` via `POST /v1/appview/enroll`, then leave Charybdis running for Jetstream/Tap and RSS poll ingestion.
3. Use Bruno `services/gateway/bruno/AppView/` or `services/appview/bruno/` to confirm timeline rows appear.

## Related

- [AppView test plan](./appview.md)
- [Thin AppView architecture](../architecture/appview.md)
