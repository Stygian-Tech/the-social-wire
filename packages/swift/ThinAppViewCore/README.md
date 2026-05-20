# ThinAppViewCore

Shared Swift package for the optional **Thin AppView** read index — Level-1 entry rows and derived read marks in Postgres/SQLite.

Consumed by:

- **`services/api`** — `/v1/appview/*` read routes, enroll, purge
- **`services/worker`** — Jetstream firehose ingestion + TTL cleanup

## Modules

| Type | Files |
|------|-------|
| Indexing | `ThinAppViewIndexer`, `RenderFieldExtractor` |
| Storage | `SQLiteThinAppViewStore`, `PostgresThinAppViewStore`, `ThinAppViewStore` |
| Worker | `ThinAppViewWorkerRuntime`, `FirehoseSubscriber`, `ThinAppViewTtlCleanupJob` |
| Config | `ThinAppViewConfig`, `RuntimeEnvironment`, `PostgresConfig` |
| Query | `ThinAppViewQuerySupport`, `ThinAppViewModels` |

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

CI runs this in `test-api` and `test-worker` jobs.

## Architecture

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## Related

- [Worker test plan](../../docs/test-plans/worker.md)
- [Worker README](../../services/worker/README.md)
