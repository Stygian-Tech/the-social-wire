# Thin AppView

Social Wire’s **data-minimized read index** — the current signed-in client read path, server feature-gated, and distinct from the Bluesky **`public.api.bsky.app`** App View.

**Canonical design doc (repo):** [docs/architecture/appview.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)

## What it is

| Layer | Role |
|-------|------|
| **Bluesky App View** | Public social graph (`getProfile`, `getFollows`, …) — **unchanged** |
| **Thin AppView** (`/v1/appview/*` on **`services/appview`**, proxied by **`services/gateway`**) | Entry timelines and detail, unread counts, bootstrap stream, scoped mark-all-read |
| **Publication sidebar** (`/v1/publications/*` on **`services/appview`**, proxied by gateway) | Server-side discovery, folders, subscriptions, RSS rows, unread badges |

For `standard.site`, the index stores render/detail fields (title, `publishedAt`, summary, thumbnail and canonical URL references) while the source records remain authoritative on each author’s PDS. Skyreader RSS ingestion may retain feed-provided content HTML. Feed read/unread state is local-first in clients and synchronized to Social Wire AppView, not written as ATProto repo records.

## Data flow

```
Jetstream / environment-matched Tap
        │
        ▼
Railway Charybdis (`appview-worker`) — ATProto ingest, Skyreader RSS polling, proactive PDS backfill, TTL cleanup
        │
        ▼
Railway Postgres — content_items, read_marks, sidebar/unread/first-page caches, …
        │
        ▼
Railway AppView — /v1/appview/*, /v1/publications/*
        │
        ▼
Railway Gateway — OAuth/DPoP, PDS write-through, unbuffered AppView proxy
        │
        ├── Web (NEXT_PUBLIC_USE_THIN_APPVIEW)
        └── iOS (SOCIALWIRE_USE_THIN_APPVIEW)
```

**Initial reader load:** authenticated NDJSON **`GET /v1/appview/bootstrap-stream`** (gateway proxies AppView without buffering) — progressive sidebar priority, per-folder `sidebarSection` slices, unread counts, first-unread selection, first feed page. Repeat visits paint persisted cache while the stream refreshes.

**Consistency:** clients update local read state immediately, then write AppView read marks or scoped read floors. Firehose, enrollment, and proactive backfill keep content rows current.

**Repairing stale rows:** `POST /v1/appview/enroll` with `authorDids` re-indexes an author's recent records on demand — the manual lever when a projection change (for example newly resolvable standard.site article URLs) needs to reach rows indexed before the change shipped. Proactive backfill reaches every author on its own cycle, and the `content_items` TTL eventually expires the rest.

## HTTP routes

All routes require ATProto OAuth (`Authorization: Bearer` or `DPoP` + `DPoP` proof) unless noted. **`ENABLE_THIN_APPVIEW=true`** on AppView registers `/v1/appview/*`; gateway always exposes OAuth metadata and proxies AppView when **`APPVIEW_BASE_URL`** is set.

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
| `DELETE` | `/v1/appview/privacy/purge` | Delete all indexed read marks for the authenticated viewer |

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
| `sidebar_projection_cache` | Stale-first sidebar payloads per viewer |
| `unread_counts_cache` | Stale-first unread-count payloads per viewer |
| `first_page_cache` | Stale-first first-feed-page payloads per viewer |
| `pds_repo_record_cache` | Short TTL sync accelerator (gateway) |

Local dev mirrors tables in SQLite via `ThinAppViewStore` / gateway cache stores.

## Feature flags

| Surface | Flag | Default |
|---------|------|---------|
| AppView HTTP routes | `ENABLE_THIN_APPVIEW` | off |
| Charybdis ingest | `ENABLE_THIN_APPVIEW=true` on Charybdis | off |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW` | on unless explicitly `false` |
| iOS client | AppView route availability | on until a route returns unavailable; the compile flag currently gates Profile purge UI |

When the server flag is off, AppView routes are unavailable. Current web and iOS builds do not offer a complete PDS-direct feed/detail fallback; legacy gateway `/discovery` and `/entries` routes are separately gated by **`ENABLE_LEGACY_CONTENT_API`** and are not the default path.

## Environment

| Variable | Service | Description |
|----------|---------|-------------|
| `ENABLE_THIN_APPVIEW` | appview, appview-worker | Mount `/v1/appview/*` and enable store bootstrap |
| `APPVIEW_BASE_URL` | gateway | Internal AppView base URL for proxy routes |
| `GATEWAY_APPVIEW_INTERNAL_SECRET` | gateway + appview | HMAC trust for gateway→AppView proxy |
| `DATABASE_URL` | gateway, appview, appview-worker, operations | Railway Postgres private connection URL |
| `THIN_APPVIEW_RELAY_WS_URLS` | appview-worker | Ordered, comma-separated Jetstream WebSocket URLs for active/passive failover (`THIN_APPVIEW_RELAY_WS_URL` remains a compatible single-primary override) |
| `TAP_BASE_URL` / `TAP_CONSUMER_MODE` | appview-worker | Environment-scoped Tap endpoint and shadow/authoritative transport mode |
| `THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED` | appview-worker | Periodic PDS backfill for subscribed authors |
| `THIN_APPVIEW_CONTENT_TTL_SECONDS` | appview-worker | `content_items.expires_at` horizon |
| `THIN_APPVIEW_READ_MARK_TTL_SECONDS` | appview-worker | `read_marks` retention |

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
All hosted services use their environment's Railway Postgres service.

**Rollout checklist**

1. Confirm Gateway's pre-deploy migration command succeeds against the environment's Railway Postgres service.
2. Deploy Charybdis with `ENABLE_THIN_APPVIEW=true`.
3. Deploy AppView with `ENABLE_THIN_APPVIEW=true`.
4. Deploy Gateway with `APPVIEW_BASE_URL` + shared internal secret.
5. Ensure the web deployment does not explicitly set `NEXT_PUBLIC_USE_THIN_APPVIEW=false`, then validate preview and production.
6. Validate iOS against the testing gateway before App Store rollout.

## Client integration

### Web

- **Initial load:** `usePublicationSidebarData` → `GET /v1/appview/bootstrap-stream`
- **Entry lists and aggregate feeds:** `useEntries` → `GET /v1/appview/entries` or `/v1/appview/feed`; **`useProactiveFeedRefresh`** polls/refocus-refreshes the active feed
- **Entry detail:** `useEntry` → `GET /v1/appview/entry`, with narrow author-PDS URL/embed enrichment for incomplete standard.site detail
- **Sidebar:** `publicationProjectionClient` / `socialWireGatewayClient`
- **Read state:** local optimistic cache + AppView read marks/read floors; scoped mark-all-read via gateway
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
- **Logging:** routes log `{ method, path, status, latency_ms }` only — no `Authorization` / `DPoP` bodies
- **User control:** Purge endpoint + iOS Profile action
- **Authority:** user-authored records remain on the PDS and indexed projections are rebuildable

## Related

- [[Service-API]] — gateway + appview runbook
- [[ThinAppViewCore]] — shared Swift indexing library
- [[Architecture]] — PDS-first principles
