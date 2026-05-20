# Worker test plan

**Package:** `services/worker`  
**Shared library:** `packages/swift/ThinAppViewCore`  
**CI:** `test-worker`

## Commands

```bash
# Shared core (indexed first in CI)
cd packages/swift/ThinAppViewCore
swift test

# Worker CLI + wiring
cd services/worker
swift test
swift build   # compile check
```

## Test layout

```
services/worker/Tests/WorkerTests/
  WorkerCommandTests.swift

packages/swift/ThinAppViewCore/Tests/ThinAppViewCoreTests/
  ThinAppViewTests.swift
  ThinAppViewIndexerTests.swift
  ThinAppViewQuerySupportTests.swift
  RenderFieldExtractorTests.swift
  Fixtures/                  # static commit JSON (no live firehose)
```

## ThinAppViewCore

The worker executable delegates to `ThinAppViewWorkerRuntime` from ThinAppViewCore. Core tests cover:

- `RenderFieldExtractor` — publication/entry field extraction
- `SQLiteThinAppViewStore` — indexing, unread filtering
- `ThinAppViewIndexer` — fixture commit → `IndexedContentItem`
- `ThinAppViewQuerySupport` — pagination SQL

Postgres store tests are integration-level; local dev uses SQLite via `APP_ENV=local`.

## Worker tests

- CLI argument parsing (`WorkerCommand`)
- Env loading for `ENABLE_THIN_APPVIEW`, relay URL, TTL vars
- Runtime bootstrap with in-memory SQLite (no network)

## Manual verification (ingestion)

The worker has no HTTP surface. Verify via API AppView routes:

1. Run worker: `APP_ENV=local ENABLE_THIN_APPVIEW=true swift run Worker`
2. Enroll author DIDs via `POST /v1/appview/enroll`
3. Use Bruno `services/worker/bruno/` or `services/api/bruno/AppView/` to confirm timeline rows appear

## Related

- [services/worker/README.md](../../services/worker/README.md)
- [Thin AppView architecture](../architecture/appview.md)
