# ThinAppViewCore

Shared Swift package for the optional **Thin AppView** read index — Level-1 entry rows, derived read marks, and sidebar projection caches in Postgres/SQLite.

Consumed by:

- **`services/appview`** — `/v1/appview/*`, `/v1/publications/*`, bootstrap stream
- **`services/appview-worker`** — Jetstream firehose ingestion, proactive backfill, TTL cleanup

## Modules

| Type | Files |
|------|-------|
| Indexing | `ThinAppViewIndexer`, `RenderFieldExtractor` |
| Storage | `SQLiteThinAppViewStore`, `PostgresThinAppViewStore`, `ThinAppViewStore` |
| Projection cache | `AppViewProjectionCacheStore`, `SQLiteAppViewProjectionCacheStore`, `PostgresAppViewProjectionCacheStore` |
| Worker | `ThinAppViewWorkerRuntime`, `FirehoseSubscriber`, `ThinAppViewTtlCleanupJob`, `ThinAppViewProactiveBackfillJob` |
| Config | `ThinAppViewConfig`, `RuntimeEnvironment`, `PostgresConfig` |
| Query | `ThinAppViewQuerySupport`, `ThinAppViewModels` |

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

CI runs this in **`test-appview`** and **`test-appview-worker`** jobs.

## Architecture

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## Related

- [AppView worker test plan](../../docs/test-plans/worker.md)
- [AppView test plan](../../docs/test-plans/appview.md)
