# Thin AppView

Social Wire’s **data-minimized read index** — the current signed-in client read path, server feature-gated, and distinct from the Bluesky **`public.api.bsky.app`** App View.

**Canonical design doc (repo):** [docs/architecture/appview.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)

## What it is

| Layer | Role |
|-------|------|
| **Bluesky App View** | Public social graph (`getProfile`, `getFollows`, …) — **unchanged** |
| **Thin AppView** (hosted `/v1/appview/*`; pending source adds `/xrpc/app.thesocialwire.appview.*`, proxied by **`services/gateway`**) | Entry timelines and detail, unread counts, bootstrap stream, scoped mark-all-read |
| **Publication sidebar** (hosted `/v1/publications/*`; pending source adds `/xrpc/app.thesocialwire.publication.*`, proxied by gateway) | Server-side discovery, folders, subscriptions, RSS rows, unread badges |

For `standard.site`, the index stores render/detail fields (title, `publishedAt`, summary, thumbnail and canonical URL references) while the source records remain authoritative on each author’s PDS. Skyreader RSS ingestion may retain feed-provided content HTML. Feed read/unread state is local-first in clients and synchronized to Social Wire AppView. Current clients do not write it to an ATProto read-state collection.

## Data flow

```
Jetstream / environment-matched Tap
        │
        ▼
Railway Charybdis (`appview-worker`) — ATProto ingest, Skyreader RSS polling, proactive PDS backfill, TTL cleanup
        │
        ▼
Railway Postgres — content_items, read marks/floors, materialized counters, ingestion/repair state
        │
Optional private Redis side-cache — currently selected in Development and Production
        │
        ▼
Railway AppView — hosted /v1/* + NDJSON bootstrap stream; pending /xrpc/app.thesocialwire.* aliases
        │
        ▼
Railway Gateway — OAuth/DPoP, PDS write-through, unbuffered AppView proxy
        │
        ├── Web (NEXT_PUBLIC_USE_THIN_APPVIEW)
        └── iOS (SOCIALWIRE_USE_THIN_APPVIEW)
```

**Initial reader load:** authenticated NDJSON **`GET /v1/appview/bootstrap-stream`** (gateway proxies AppView without buffering) — progressive sidebar priority, per-folder `sidebarSection` slices, unread counts, first-unread selection, first feed page. Repeat visits paint persisted cache while the stream refreshes.

See [[Redis]] for cache TTLs, failure semantics, ranking primitives, the current
hosted selection, and Development-first change discipline. Postgres remains the
durable source and cache rollback backend.

**Consistency:** clients update local read state immediately, then write AppView read marks or scoped read floors. Firehose, enrollment, and proactive backfill keep content rows current.

**Repairing stale rows:** `app.thesocialwire.appview.enrollSources` (or its
`POST /v1/appview/enroll` compatibility route) with `authorDids` re-indexes an
author's recent records on demand — the manual lever when a projection change
(for example newly resolvable standard.site article URLs) needs to reach rows
indexed before the change shipped. Proactive backfill reaches every author on
its own cycle, and the `content_items` TTL eventually expires the rest.

## HTTP routes

All routes require ATProto OAuth (`Authorization: Bearer` or `DPoP` + `DPoP` proof) unless noted. **`ENABLE_THIN_APPVIEW=true`** on AppView registers the AppView XRPC and compatibility `/v1/appview/*` surfaces; gateway always exposes OAuth metadata and proxies AppView when **`APPVIEW_BASE_URL`** is set.

The current checkout migrates eligible JSON operations to Lexicon-defined
`/xrpc/app.thesocialwire.appview.*` queries and procedures while retaining the
`/v1/*` paths below. The XRPC aliases are not yet registered on the public
Testing or Production gateways as of 2026-08-12, so `/v1/*` remains the current
hosted contract. `bootstrap-stream` stays HTTP NDJSON because it is a
progressive stream rather than a normal XRPC JSON response. See [[Service-API]]
and [[Lexicons]].

### AppView (read index)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/appview/bootstrap-stream` | Progressive NDJSON initial load (sidebar, unread, first page) |
| `GET` | `/v1/appview/entries` | Paginated timeline (`authorDid`, scope keys, `filter=all\|unread\|read`, optional `maxEntries`) |
| `GET` | `/v1/appview/feed` | Aggregate Subscribed, Following, folder, or publication feed |
| `GET` | `/v1/appview/entry` | Flat indexed entry-detail object |
| `GET` | `/v1/appview/unread-counts` | Unread badges by publication or scope |
| `POST` | `/v1/appview/read-marks` | Upsert AppView read mark |
| `DELETE` | `/v1/appview/read-marks` | Delete AppView read mark |
| `POST` | `/v1/appview/enroll` | Backfill recent author records (`authorDids`) and/or ingest subscribed RSS feeds (`feedUrls`) |
| `POST` | `/v1/appview/mark-all-read` | Scoped mark-all-read (publication, folder, subscribed, following) |
| `DELETE` | `/v1/appview/privacy/purge` | Delete the viewer's explicit read marks and unread overrides; bulk-read floors and other projection rows remain |

### Publications (sidebar projection)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/publications/sidebar` | Unified sidebar (`phase=full\|priority\|folderPublications`) |
| `POST` | `/v1/publications/refresh` | Recompute sidebar projection |
| `POST` | `/v1/publications/resolve` | Resolve Add Publication input |

Gateway exposes PDS write-through routes at `/v1/publications/folders`, `/prefs`, `/subscriptions`, and `/rss-subscriptions`. The web client normally writes these records directly to the viewer PDS; the current iOS app uses the Gateway routes with an upstream PDS-bound DPoP proof.

OpenAPI: [packages/spec/openapi.yaml](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Database

Migrations under [`database/migrations/`](https://github.com/Stygian-Tech/the-social-wire/tree/main/database/migrations):

| Table | Purpose |
|-------|---------|
| `content_items` | Data-minimized standard.site rows and parsed RSS content rows keyed by entry URI |
| `read_marks` | AppView unread state per `(viewer_did, subject_uri)` |
| `sidebar_projection_cache` | Sidebar payloads when the environment selects the Postgres cache backend; Redis rollback target otherwise |
| `unread_counts_cache` | Unread payloads when the environment selects Postgres; Redis rollback target otherwise |
| `first_page_cache` | First-feed-page payloads when the environment selects Postgres; Redis rollback target otherwise |
| `pds_repo_record_cache` | Gateway PDS cache in Postgres mode; Redis rollback target otherwise |

SQLite stores remain implemented, but the current service entry points reject `APP_ENV=local` through their shared Operations environment guard. Runnable local integration currently uses `APP_ENV=dev` and an isolated disposable Postgres database. See [[Contributing]].

## Feature flags

| Surface | Flag | Default |
|---------|------|---------|
| AppView HTTP routes | `ENABLE_THIN_APPVIEW` | off |
| Charybdis ingest | `ENABLE_THIN_APPVIEW=true` on Charybdis | off |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW` | on unless explicitly `false` |
| iOS client | AppView route availability | used until a route reports unavailable; the compile flag gates Profile purge UI |

When the server flag is off, AppView routes are unavailable. Current web and iOS builds do not offer a complete PDS-direct feed/detail fallback; legacy gateway `/discovery` and `/entries` routes are separately gated by **`ENABLE_LEGACY_CONTENT_API`** and are not the default path.

## Environment

| Variable | Service | Description |
|----------|---------|-------------|
| `ENABLE_THIN_APPVIEW` | appview, appview-worker | Mount the AppView XRPC/compatibility routes and enable store bootstrap |
| `APPVIEW_BASE_URL` | gateway | Internal AppView base URL for proxy routes |
| `GATEWAY_APPVIEW_INTERNAL_SECRET` | gateway + appview | HMAC trust for gateway→AppView proxy |
| `DATABASE_URL` | gateway, appview, appview-worker, operations | Railway Postgres private connection URL |
| `THIN_APPVIEW_RELAY_WS_URLS` | appview-worker | Ordered, comma-separated Jetstream WebSocket URLs for active/passive failover (`THIN_APPVIEW_RELAY_WS_URL` remains a compatible single-primary override) |
| `TAP_BASE_URL` / `TAP_CONSUMER_MODE` | appview-worker | Environment-scoped Tap endpoint and shadow/authoritative transport mode |
| `THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED` | appview-worker | Periodic PDS backfill for subscribed authors |
| `THIN_APPVIEW_CONTENT_TTL_SECONDS` | appview, appview-worker | `content_items.expires_at` horizon used by stores and worker cleanup |
| `THIN_APPVIEW_READ_MARK_TTL_SECONDS` | appview, appview-worker | `read_marks` retention used by stores and worker cleanup |
| `GATEWAY_PDS_CACHE_BACKEND` | gateway | Select `postgres` or `redis` for hosted PDS-record caching |
| `APPVIEW_CACHE_BACKEND` | appview, appview-worker | Select `postgres` or `redis` for hosted projection caching |
| `REDIS_URL` | gateway, appview, appview-worker | Private Redis connection when the Redis backend is selected |

## Deployment (Railway)

Railway deploys seven independent services per environment from repository-level config-as-code files:

| Service | Config |
|---------|--------|
| Web | `railway/web.json` |
| Operations Web | `railway/operations-web.json` |
| Gateway | `railway/gateway.json` |
| AppView | `railway/appview.json` |
| Charybdis | `railway/charybdis.json` |
| Operations | `railway/operations.json` |
| Tap | `railway/tap.json` |

Development tracks `dev`; production tracks `main`. Gateway reaches AppView and
Operations over Railway private domains, and Charybdis reaches Tap the same way.
Database-backed hosted services use their environment's Railway Postgres
service. Redis is optional and does not replace Postgres. During the current
hosted configuration, both environments select Redis backends, while Postgres
remains durable and its cache tables remain the rollback target.

**Rollout checklist**

1. Confirm Gateway's pre-deploy migration command succeeds against the environment's Railway Postgres service.
2. Deploy Charybdis with `ENABLE_THIN_APPVIEW=true`.
3. Deploy AppView with `ENABLE_THIN_APPVIEW=true`.
4. Deploy Gateway with `APPVIEW_BASE_URL` and the shared internal secret.
5. Ensure the web deployment does not explicitly set `NEXT_PUBLIC_USE_THIN_APPVIEW=false`.
6. Validate signed-in Web and iOS flows against the testing gateway before Production or App Store changes.
7. Treat future Redis changes as their own Development-first rollout; Redis is not required for correctness of the AppView read path.

## Client integration

### Web

- **Release boundary:** hosted clients still use the `/v1/*` equivalents below until the pending XRPC source ships
- **Initial load:** `usePublicationSidebarData` → `GET /v1/appview/bootstrap-stream`
- **Entry lists and aggregate feeds:** `useEntries` → `app.thesocialwire.appview.listEntries` or `getFeed`; **`useProactiveFeedRefresh`** polls/refocus-refreshes the active feed
- **Entry detail:** `useEntry` → `app.thesocialwire.appview.getEntry`, with narrow author-PDS URL/embed enrichment for incomplete standard.site detail
- **Sidebar:** `publicationProjectionClient` / `socialWireGatewayClient`
- **Read state:** local optimistic cache + AppView read marks/read floors; scoped mark-all-read via gateway; no current PDS read-state record
- Env: `NEXT_PUBLIC_SOCIALWIRE_API_URL` (default `https://api.thesocialwire.app`)

See [[Web-app]].

### iOS

- **Initial load:** same bootstrap-stream NDJSON contract as web
- `SocialWireGatewayClient` — sidebar, AppView feeds and entry detail, read marks, enroll, mark-all-read, purge
- Profile → **Purge Indexed Data** (confirmation step)

See [[Apple-client]].

## Privacy

- **Region:** compute and Postgres placement are Railway environment settings; verify those settings directly before making data-residency claims
- **Retention:** TTL on indexed rows (configurable)
- **Telemetry:** Operations request metrics use bounded service/operation/status/latency dimensions and omit authorization headers, DPoP proofs, bodies, cursors, user agents, and fingerprinting identifiers
- **Diagnostic logs:** selected authentication, bootstrap, and purge messages may include a viewer DID for diagnosis; do not describe all service logs as anonymous or identifier-free
- **User control:** Purge endpoint + iOS Profile action remove explicit read marks and unread overrides; they are not a complete account-data deletion
- **Authority:** user-authored records remain on the PDS and indexed projections are rebuildable

## Related

- [[Service-API]] — gateway + appview runbook
- [[ThinAppViewCore]] — shared Swift indexing library
- [[Architecture]] — PDS-first principles
