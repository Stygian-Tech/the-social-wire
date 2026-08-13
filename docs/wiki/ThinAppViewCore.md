# ThinAppViewCore

Shared Swift package for the Thin AppView read index — used by **`services/appview`** (read routes, sidebar projection) and **Charybdis** at `services/appview-worker` (Jetstream/Tap ingestion, RSS polling, proactive backfill).

**Package:** [packages/swift/ThinAppViewCore](https://github.com/Stygian-Tech/the-social-wire/tree/main/packages/swift/ThinAppViewCore)  
**Architecture:** [[Thin-AppView]]

## Responsibilities

| Component | Role |
|-----------|------|
| `ThinAppViewIndexer` | Map firehose/repo commits → `IndexedContentItem` |
| `RenderFieldExtractor` | Extract list-row fields from standard.site records |
| `AppViewProjectionCacheStore` | Stale-first sidebar/unread/first-page snapshots, with SQLite, Postgres, or Redis implementations |
| `SQLiteThinAppViewStore` / `PostgresThinAppViewStore` | Equivalent index stores; hosted services use Postgres, while SQLite remains useful in package tests |
| `ThinAppViewWorkerRuntime` | Jetstream/Tap ingestion, Skyreader RSS polling, proactive PDS backfill, and TTL cleanup |
| `FirehoseSubscriber` | Jetstream WebSocket relay consumer and cursor recovery |
| `RssFeedIdentity` / RSS ingest helpers | Normalize feed/article identities and avoid duplicate rows across polls |

The package also owns unread filtering, publication-scope aliases, materialized
counter updates, viewer-feed membership, Tap recovery state, and cache
invalidation. Redis remains an optional disposable side-cache; durable index and
recovery state stays in Postgres. See [[Redis]] for the current hosted selection
and Development-first change discipline.

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

Runs explicitly in the CI **`charybdis`** job. Redis client behavior is tested
separately in `packages/swift/SocialWireRedis`, including a live Redis service in
CI.

## Related

- [[Service-API]] — HTTP surfaces on gateway + appview
- [[Database]] — durable and rebuildable table ownership
- [[Redis]] — optional cache and coordination layer
- [[Web-app]] / [[Apple-client]] — client flags
- [Charybdis test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md)
