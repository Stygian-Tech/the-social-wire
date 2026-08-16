# Architecture

The Social Wire separates portable user records from rebuildable application projections.

| Layer | Responsibility |
|-------|----------------|
| **Web and Apple clients** | ATProto sign-in, direct or gateway-assisted PDS writes, local cache, reader UI |
| **Gateway** | Public OAuth/DPoP edge, sync acceleration, publication writes for native clients, L@tr/Operations proxies, unbuffered AppView proxy |
| **AppView** | Publication sidebar, indexed timelines/detail, unread state, bootstrap stream |
| **Charybdis** | Jetstream ingestion and durable-inbox projection, RSS polling, backfill, repair, and retention cleanup |
| **Jetstream V2 Ingest** | Fenced Jetstream V2 staging into PostgreSQL |
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

Jetstream V1 -------- Charybdis ---- Postgres
Jetstream V2 Ingest -------┘
RSS/Atom feeds -----------^             `---- optional Redis leases/cache
```

## Canonical deep dives

- [Architecture overview](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/overview.md)
- [Discovery chain](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/discovery.md)
- [Lexicon architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md)
- [AppView architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)
- [Redis cache and coordination](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/redis.md)

Related: [[Thin-AppView]], [[Service-API]], [[Database]], [[Redis]], [[Lexicons]].
