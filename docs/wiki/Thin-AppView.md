# Thin AppView

Social Wire’s **GDPR-safe Level-1 read index** — optional, feature-flagged, and distinct from the Bluesky **`public.api.bsky.app`** App View.

**Canonical design doc (repo):** [docs/architecture/appview.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)

## What it is

| Layer | Role |
|-------|------|
| **Bluesky App View** | Public social graph (`getProfile`, `getFollows`, …) — **unchanged** |
| **Thin AppView** (`/v1/appview/*` on `services/api`) | Level-1 entry timelines + server-side unread filtering |

The thin index stores **list-row fields only** (title, `publishedAt`, summary, thumbnail URL refs) for `standard.site` entry collections. **Full entry bodies** and **canonical read writes** stay on each user’s PDS (`com.thesocialwire.entryReadState`).

## Data flow

```
Jetstream / relay (subscribeRepos)
        │
        ▼
Fly worker (App worker) — firehose ingest + TTL cleanup
        │
        ▼
Supabase Postgres (ams) — content_items, read_marks
        │
        ▼
Fly API (App serve) — /v1/appview/*
        │
        ├── Web (NEXT_PUBLIC_USE_THIN_APPVIEW)
        └── iOS (SOCIALWIRE_USE_THIN_APPVIEW)
```

**Consistency:** PDS first for read marks; clients write-through to the index after successful PDS upsert/delete. Firehose + enrollment backfill reconcile drift.

## HTTP routes

All routes require ATProto OAuth (`Authorization: Bearer` or `DPoP` + `DPoP` proof). Mounted only when **`ENABLE_THIN_APPVIEW=true`** on the gateway.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/appview/entries` | Paginated timeline (`authorDid`, optional `publicationAtUri`, `filter=all\|unread\|read`) |
| `POST` | `/v1/appview/read-marks` | Write-through read mark after PDS upsert |
| `DELETE` | `/v1/appview/read-marks` | Write-through unread (delete mark) |
| `POST` | `/v1/appview/enroll` | Backfill recent entries for followed author DIDs (max 500) |
| `DELETE` | `/v1/appview/privacy/purge` | Delete all indexed read marks for the authenticated viewer |

OpenAPI: [packages/spec/openapi.yaml](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Database

Migration: [`supabase/migrations/20260519120000_add_thin_appview.sql`](https://github.com/Stygian-Tech/the-social-wire/blob/main/supabase/migrations/20260519120000_add_thin_appview.sql)

| Table | Purpose |
|-------|---------|
| `content_items` | Level-1 timeline rows keyed by entry AT-URI |
| `read_marks` | Derived unread state per `(viewer_did, subject_uri)` — not authoritative vs PDS |

Local dev mirrors both tables in SQLite via `ThinAppViewStore` (separate from legacy discovery cache).

## Feature flags

| Surface | Flag | Default |
|---------|------|---------|
| Gateway HTTP routes | `ENABLE_THIN_APPVIEW` | off |
| Firehose worker | `ENABLE_THIN_APPVIEW=true` on worker Fly app | off |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW=true` | off |
| iOS client | `SOCIALWIRE_USE_THIN_APPVIEW` (Swift compile condition) | off |

When flags are off, clients continue PDS-direct `listRecords` entry loading.

## Gateway environment

See [services/api/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/services/api/README.md) and [services/api/.env.example](https://github.com/Stygian-Tech/the-social-wire/blob/main/services/api/.env.example).

| Variable | Description |
|----------|-------------|
| `ENABLE_THIN_APPVIEW` | Mount `/v1/appview/*` and enable store bootstrap |
| `THIN_APPVIEW_RELAY_WS_URL` | Jetstream-compatible WebSocket URL (defaults to filtered Bluesky Jetstream) |
| `THIN_APPVIEW_CONTENT_TTL_SECONDS` | `content_items.expires_at` horizon (default 30 days) |
| `THIN_APPVIEW_READ_MARK_TTL_SECONDS` | `read_marks` retention (default 180 days) |
| `THIN_APPVIEW_MAX_ENROLL_AUTHORS` | Cap for `POST /v1/appview/enroll` (default 500) |

## Deployment (Fly)

Two processes from the same Docker image:

| Process | Config | Command |
|---------|--------|---------|
| API | `services/api/fly.toml` | `App serve` (default) |
| Worker | `services/api/fly.worker.toml` | `App worker` |

Both use **`primary_region = ams`** (EU co-location with Supabase).

**Rollout checklist**

1. Apply Supabase migration on dev, then prod (`supabase db push` via Actions or CLI).
2. Deploy API with `ENABLE_THIN_APPVIEW=true`.
3. Deploy worker app with `ENABLE_THIN_APPVIEW=true`.
4. Enable web flag on Vercel preview → validate → prod.
5. Ship iOS with `SOCIALWIRE_USE_THIN_APPVIEW` on testing builds first.

## Client integration

### Web

- Module: `apps/web/src/lib/thinAppViewClient.ts`
- Hook: `useEntries` routes to gateway when `NEXT_PUBLIC_USE_THIN_APPVIEW=true`
- Write-through: `pdsClient.putEntryReadState` / `deleteEntryReadState`
- Enrollment: `usePublications` after `discoverPublications` completes
- Env: `NEXT_PUBLIC_SOCIALWIRE_API_URL` (default `https://api.thesocialwire.app`)

See [[Web-app]].

### iOS

- `SocialWireGatewayClient` — appview entries, read marks, enroll, purge
- `SocialWireAppModel.loadEntries` — gateway when `SocialWireAPIEnvironment.useThinAppView`
- Profile → **Purge Indexed Data** (confirmation step)

See [[Apple-client]].

## Privacy

- **Region:** Fly + Supabase in **`ams`**
- **Retention:** TTL on indexed rows (configurable)
- **Logging:** AppView routes log `{ method, path, status, latency_ms }` only — no `Authorization` / `DPoP` bodies
- **User control:** Purge endpoint + iOS Profile action

## Related

- [[Service-API]] — gateway runbook
- [[Architecture]] — PDS-first principles
- Future cross-user indexer (not thin AppView): noted in [appview.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md)
