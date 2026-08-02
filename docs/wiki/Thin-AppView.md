# Thin AppView

Social Wire’s **data-minimized Level-1 read index** — optional, feature-flagged, and distinct from the Bluesky **`public.api.bsky.app`** App View.

**Canonical design doc (repo):** [docs/architecture/appview.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)

## What it is

| Layer | Role |
|-------|------|
| **Bluesky App View** | Public social graph (`getProfile`, `getFollows`, …) — **unchanged** |
| **Thin AppView** (`/v1/appview/*` on **`services/appview`**, proxied by **`services/gateway`**) | Level-1 entry timelines, unread counts, bootstrap stream, scoped mark-all-read |
| **Publication sidebar** (`/v1/publications/*` on **`services/appview`**, proxied by gateway) | Server-side discovery, folders, subscriptions, RSS rows, unread badges |

The thin index stores **list-row fields only** (title, `publishedAt`, summary, thumbnail URL refs) for `standard.site` entry collections. **Full entry bodies** stay on each author’s PDS. Feed read/unread state is local-first in clients and synchronized to Social Wire AppView, not written as ATProto repo records.

## Data flow

```
Jetstream / relay (subscribeRepos)
        │
        ▼
Fly Charybdis (`appview-worker`) — firehose ingest, proactive PDS backfill, TTL cleanup
        │
        ▼
Supabase Postgres (AWS us-east-1) — content_items, read_marks, sidebar_projection_cache, …
        │
        ▼
Fly appview — /v1/appview/*, /v1/publications/*
        │
        ▼
Fly gateway — OAuth/DPoP, PDS write-through, unbuffered AppView proxy
        │
        ├── Web (NEXT_PUBLIC_USE_THIN_APPVIEW)
        └── iOS (SOCIALWIRE_USE_THIN_APPVIEW)
```

**Initial reader load:** authenticated NDJSON **`GET /v1/appview/bootstrap-stream`** (gateway proxies AppView without buffering) — progressive sidebar priority, per-folder `sidebarSection` slices, unread counts, first-unread selection, first feed page. Repeat visits paint persisted cache while the stream refreshes.

**Consistency:** clients update local read state immediately, then write AppView read marks or scoped read floors. Firehose, enrollment, and proactive backfill keep content rows current.

## HTTP routes

All routes require ATProto OAuth (`Authorization: Bearer` or `DPoP` + `DPoP` proof) unless noted. **`ENABLE_THIN_APPVIEW=true`** on AppView registers `/v1/appview/*`; gateway always exposes OAuth metadata and proxies AppView when **`APPVIEW_BASE_URL`** is set.

### AppView (read index)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/appview/bootstrap-stream` | Progressive NDJSON initial load (sidebar, unread, first page) |
| `GET` | `/v1/appview/entries` | Paginated timeline (`authorDid`, scope keys, `filter=all\|unread\|read`, optional `maxEntries`) |
| `GET` | `/v1/appview/entry` | Level-1 entry detail from index |
| `GET` | `/v1/appview/unread-counts` | Unread badges by publication or scope |
| `POST` | `/v1/appview/read-marks` | Upsert AppView read mark |
| `DELETE` | `/v1/appview/read-marks` | Delete AppView read mark |
| `POST` | `/v1/appview/enroll` | Backfill recent entries for author DIDs (max 500) |
| `POST` | `/v1/appview/mark-all-read` | Scoped mark-all-read (publication, folder, subscribed, following) |
| `DELETE` | `/v1/appview/privacy/purge` | Delete all indexed read marks for the authenticated viewer |

### Publications (sidebar projection)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/publications/sidebar` | Unified sidebar (`phase=full\|priority\|folderPublications`) |
| `POST` | `/v1/publications/refresh` | Recompute sidebar projection |
| `POST` | `/v1/publications/resolve` | Resolve Add Publication input |

Gateway write-through (PDS repo records): `/v1/publications/folders`, `/prefs`, `/subscriptions`, `/rss-subscriptions`.

OpenAPI: [packages/spec/openapi.yaml](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Database

Migrations under [`supabase/migrations/`](https://github.com/Stygian-Tech/the-social-wire/tree/main/supabase/migrations):

| Table | Purpose |
|-------|---------|
| `content_items` | Level-1 timeline rows keyed by entry AT-URI |
| `read_marks` | AppView unread state per `(viewer_did, subject_uri)` |
| `sidebar_projection_cache` | Stale-first sidebar/unread/first-page snapshots per viewer |
| `pds_repo_record_cache` | Short TTL sync accelerator (gateway) |

Local dev mirrors tables in SQLite via `ThinAppViewStore` / gateway cache stores.

## Feature flags

| Surface | Flag | Default |
|---------|------|---------|
| AppView HTTP routes | `ENABLE_THIN_APPVIEW` | off |
| Charybdis ingest | `ENABLE_THIN_APPVIEW=true` on worker Fly app | off |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW=true` | off |
| iOS client | `SOCIALWIRE_USE_THIN_APPVIEW` (Swift compile condition) | off |

When flags are off, clients continue PDS-direct entry loading (legacy paths may require **`ENABLE_LEGACY_CONTENT_API`** on older gateway builds — not the default).

## Environment

| Variable | Service | Description |
|----------|---------|-------------|
| `ENABLE_THIN_APPVIEW` | appview, appview-worker | Mount `/v1/appview/*` and enable store bootstrap |
| `APPVIEW_BASE_URL` | gateway | Internal AppView base URL for proxy routes |
| `GATEWAY_APPVIEW_INTERNAL_SECRET` | gateway + appview | HMAC trust for gateway→AppView proxy |
| `SUPABASE_DATABASE_URL` | gateway, appview, appview-worker | Postgres (session pooler on Fly/CI) |
| `THIN_APPVIEW_RELAY_WS_URLS` | appview-worker | Ordered, comma-separated Jetstream WebSocket URLs for active/passive failover (`THIN_APPVIEW_RELAY_WS_URL` remains a compatible single-primary override) |
| `THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED` | appview-worker | Periodic PDS backfill for subscribed authors |
| `THIN_APPVIEW_CONTENT_TTL_SECONDS` | appview-worker | `content_items.expires_at` horizon |
| `THIN_APPVIEW_READ_MARK_TTL_SECONDS` | appview-worker | `read_marks` retention |

## Deployment (Fly)

Five independent apps per environment from repo root (`scripts/fly-deploy-*.sh` / per-service `deploy.sh`):

| App | Config | Command |
|-----|--------|---------|
| Gateway | `services/gateway/fly.toml` | `swift run Gateway` |
| AppView | `services/appview/fly.toml` | `swift run AppView` |
| Charybdis | `services/appview-worker/fly.toml` | `swift run AppViewWorker` |
| Operations | `services/operations/fly.toml` | `swift run Operations` |
| Tap | `services/tap/fly.toml` | pinned Indigo Tap image |

Development and production Gateway, AppView, Charybdis, Operations, and Tap use
**`primary_region = iah`**. Gateway reaches AppView and Operations over Fly private
`.internal` addresses, and Charybdis reaches Tap the same way. Supabase/Postgres
remains in AWS **`us-east-1`** through the session pooler.

**Rollout checklist**

1. Apply Supabase migrations on dev, then prod.
2. Deploy Charybdis through the stable `appview-worker` deployment with `ENABLE_THIN_APPVIEW=true`.
3. Deploy appview with `ENABLE_THIN_APPVIEW=true`.
4. Deploy gateway with `APPVIEW_BASE_URL` + shared internal secret.
5. Enable web flag on Vercel preview → validate → prod.
6. Ship iOS with `SOCIALWIRE_USE_THIN_APPVIEW` on testing builds first.

## Client integration

### Web

- **Initial load:** `usePublicationSidebarData` → `GET /v1/appview/bootstrap-stream`
- **Entry lists:** `useEntries` → `GET /v1/appview/entries`; **`useProactiveFeedRefresh`** polls/refocus-refreshes the active feed
- **Sidebar:** `publicationProjectionClient` / `socialWireGatewayClient`
- **Read state:** local optimistic cache + AppView read marks/read floors; scoped mark-all-read via gateway
- Env: `NEXT_PUBLIC_SOCIALWIRE_API_URL` (default `https://api.thesocialwire.app`)

See [[Web-app]].

### iOS

- **Initial load:** same bootstrap-stream NDJSON contract as web
- `SocialWireGatewayClient` — sidebar, appview entries, read marks, enroll, mark-all-read, purge
- Profile → **Purge Indexed Data** (confirmation step)

See [[Apple-client]].

## Privacy

- **Region:** all Fly compute is in **`iah`**; Supabase/Postgres is in AWS **`us-east-1`**; data residency is the United States
- **Retention:** TTL on indexed rows (configurable)
- **Logging:** routes log `{ method, path, status, latency_ms }` only — no `Authorization` / `DPoP` bodies
- **User control:** Purge endpoint + iOS Profile action
- **Authority:** user-authored records remain on the PDS and indexed projections are rebuildable

## Related

- [[Service-API]] — gateway + appview runbook
- [[ThinAppViewCore]] — shared Swift indexing library
- [[Architecture]] — PDS-first principles
