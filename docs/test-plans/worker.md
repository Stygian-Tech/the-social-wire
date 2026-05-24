# AppView worker test plan

**Package:** `services/appview-worker`  
**Shared library:** `packages/swift/ThinAppViewCore`  
**CI:** `test-appview-worker`

## Commands

```bash
# Shared core (indexed first in CI)
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
- `AppViewProjectionCacheStore` — sidebar/unread snapshot caches
- `ThinAppViewQuerySupport` — pagination SQL

Postgres store tests are integration-level; local dev uses SQLite via `APP_ENV=local`.

## Worker tests

- CLI argument parsing (`AppViewWorkerCommand`)
- Env loading for `ENABLE_THIN_APPVIEW`, relay URL, TTL vars, proactive backfill
- Runtime bootstrap with in-memory SQLite (no network)

## Manual verification (ingestion)

The worker has no HTTP surface. Verify via gateway/AppView routes:

1. Run worker: `APP_ENV=local ENABLE_THIN_APPVIEW=true swift run AppViewWorker`
2. Enroll author DIDs via `POST /v1/appview/enroll`
3. Use Bruno `services/gateway/bruno/AppView/` or `services/appview/bruno/` to confirm timeline rows appear

## Related

- [AppView test plan](./appview.md)
- [Thin AppView architecture](../architecture/appview.md)
