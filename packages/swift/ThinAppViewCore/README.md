# ThinAppViewCore

Shared Swift package for the **Thin AppView** read index — data-minimized standard.site rows, RSS content rows, derived read marks, and projection caches in Postgres/SQLite.

Consumed by:

- **`services/appview`** — `/v1/appview/*`, `/v1/publications/*`, bootstrap stream
- **`services/appview-worker`** — Jetstream/Tap ingestion, Skyreader RSS polling, proactive backfill, TTL cleanup

## Modules

| Type | Files |
|------|-------|
| Indexing | `ThinAppViewIndexer`, `RenderFieldExtractor` |
| Storage | `SQLiteThinAppViewStore`, `PostgresThinAppViewStore`, `ThinAppViewStore` |
| Projection cache | `AppViewProjectionCacheStore`, `SQLiteAppViewProjectionCacheStore`, `PostgresAppViewProjectionCacheStore` |
| Worker | `ThinAppViewWorkerRuntime`, `FirehoseSubscriber`, Tap consumers, `ThinAppViewRssFeedPollJob`, `ThinAppViewTtlCleanupJob`, `ThinAppViewProactiveBackfillJob` |
| Config | `ThinAppViewConfig`, `RuntimeEnvironment`, `PostgresConfig` |
| Query | `ThinAppViewQuerySupport`, `ThinAppViewModels` |

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

CI runs this explicitly in the **`test-appview-worker`** job.

## Architecture

See [docs/architecture/appview.md](../../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../../docs/wiki/Thin-AppView.md).

## Related

- [Charybdis test plan](../../../docs/test-plans/worker.md)
- [AppView test plan](../../../docs/test-plans/appview.md)
