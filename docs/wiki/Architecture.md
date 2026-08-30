# Architecture

The Social Wire separates portable user records from rebuildable application projections.

| Layer | Responsibility |
|-------|----------------|
| **Web and Apple clients** | ATProto sign-in, direct or gateway-assisted PDS writes, local cache, reader UI |
| **Gateway** | Public OAuth/DPoP edge, sync acceleration, publication writes for native clients, L@tr/Operations proxies, unbuffered AppView proxy |
| **AppView** | Publication sidebar, indexed timelines/detail, unread state, bootstrap stream |
| **Ingress Controller** | Independently supervised and fenced AppView/Wire Jetstream staging into PostgreSQL |
| **Projection Pool** | Horizontally scaled AppView and Wire durable-inbox projection |
| **Coordinator** | Fenced singleton RSS polling, backfill, repair, rank/enrichment, and cleanup |
| **Operations** | Operator-only health, evidence, gaps, alerts, traces, and controlled recovery |

## Data ownership

- The viewer's PDS is authoritative for folders, publication preferences, standard.site and RSS subscriptions, account preferences, and L@tr records.
- Publisher PDSes are authoritative for `site.standard.document` and `site.standard.entry` records.
- Railway Postgres contains derived content, read marks/floors, materialized feeds and counts, ingestion/repair state, RSS metadata, and Operations evidence.
- Private Redis is an optional disposable acceleration layer. It never replaces PDS or Postgres authority.
- Browser storage and Apple SwiftData caches are per-device and rebuildable.

Current clients write individual read marks and bulk-read boundaries to AppView, not to an `app.thesocialwire.entryReadState` PDS collection. Local state provides immediate UI while the server provides unread pagination and cross-client count refreshes.

## Request path

```text
Web / iOS / iPadOS
        |
        +---- viewer PDS: portable user records
        |
        +---- public ATProto: identity, graph, publisher records
        |
        `---- Gateway: authenticated Social Wire routes
                  |
                  +---- AppView ---- Postgres
                  |         `------ optional Redis cache
                  +---- Operations
                  `---- L@tr Gateway

Jetstream archive ---- Ingress Controller ---- Postgres inboxes
                                             |
                               Projection Pool + Coordinator
RSS/Atom feeds -------------------------------^ `---- optional Redis leases/cache
```

## Canonical deep dives

- [Architecture overview](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/overview.md)
- [Discovery chain](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/discovery.md)
- [Lexicon architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md)
- [AppView architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)
- [Replicated indexing services](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/indexing-services.md)
- [Redis cache and coordination](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/redis.md)

Related: [[Thin-AppView]], [[Service-API]], [[Database]], [[Redis]], [[Lexicons]].
