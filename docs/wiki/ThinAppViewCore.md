# ThinAppViewCore

Shared Swift package for the optional Thin AppView read index — used by **`services/api`** (read routes) and **`services/worker`** (firehose ingestion).

**Package:** [packages/swift/ThinAppViewCore](https://github.com/Stygian-Tech/the-social-wire/tree/main/packages/swift/ThinAppViewCore)  
**Architecture:** [[Thin-AppView]]

## Responsibilities

| Component | Role |
|-----------|------|
| `ThinAppViewIndexer` | Map firehose/repo commits → `IndexedContentItem` |
| `RenderFieldExtractor` | Extract list-row fields from standard.site records |
| `SQLiteThinAppViewStore` | Local dev / tests |
| `PostgresThinAppViewStore` | Production Supabase `content_items` / `read_marks` |
| `ThinAppViewWorkerRuntime` | Jetstream subscriber + TTL cleanup |
| `FirehoseSubscriber` | WebSocket relay consumer |

## Tests

```bash
cd packages/swift/ThinAppViewCore
swift test
```

Also runs in CI `test-api` and `test-worker` jobs.

## Related

- [[Service-API]] — `/v1/appview/*` HTTP surface
- [[Web-app]] / [[Apple-client]] — client flags
- [Worker test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md)
