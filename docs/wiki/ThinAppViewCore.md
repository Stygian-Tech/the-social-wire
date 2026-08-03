# ThinAppViewCore

Shared Swift package for the Thin AppView read index — used by **`services/appview`** (read routes, sidebar projection) and **Charybdis** at `services/appview-worker` (Jetstream/Tap ingestion, RSS polling, proactive backfill).

**Package:** [packages/swift/ThinAppViewCore](https://github.com/Stygian-Tech/the-social-wire/tree/main/packages/swift/ThinAppViewCore)  
**Architecture:** [[Thin-AppView]]

## Responsibilities

| Component | Role |
|-----------|------|
| `ThinAppViewIndexer` | Map firehose/repo commits → `IndexedContentItem` |
| `RenderFieldExtractor` | Extract list-row fields from standard.site records |
| `AppViewProjectionCacheStore` | Stale-first sidebar/unread/first-page snapshots |
| `SQLiteThinAppViewStore` / `PostgresThinAppViewStore` | Local dev / production storage |
| `ThinAppViewWorkerRuntime` | Jetstream subscriber + proactive backfill + TTL cleanup |
| `FirehoseSubscriber` | WebSocket relay consumer |

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

Runs explicitly in the CI **`charybdis`** job.

## Related

- [[Service-API]] — HTTP surfaces on gateway + appview
- [[Web-app]] / [[Apple-client]] — client flags
- [Charybdis test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md)
