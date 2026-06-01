# AppView architecture

> **Wiki summary:** [docs/wiki/Thin-AppView.md](../wiki/Thin-AppView.md) (synced to GitHub Wiki on push to **`main`** when `docs/wiki/**` changes).

Social Wire uses two distinct “AppView” concepts:

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | Public social graph reads (`getProfile`, `getFollows`, …) | Unchanged — clients call it directly |
| **Thin AppView** (`/v1/appview/*` on **`services/appview`**, proxied by **`services/gateway`**) | GDPR-safe Level-1 entry timelines, sidebar projection, server-side unread filtering | Implemented behind feature flags |

The thin AppView is **not** a Bluesky proxy. It is Social Wire’s own index of `standard.site` entry collections plus a derived `read_marks` replica for unread queries. Full entry bodies and canonical read writes remain on each user’s PDS (`app.thesocialwire.entryReadState`).

## Distributed services

| Service | Responsibility |
|---------|----------------|
| **`services/gateway`** | Public OAuth/DPoP edge, PDS write-through, sync cache, unbuffered proxy to AppView |
| **`services/appview`** | Sidebar projection (`/v1/publications/*`), Thin AppView reads (`/v1/appview/*`), bootstrap stream, projection caches |
| **`services/appview-worker`** | Jetstream ingestion, proactive PDS backfill, TTL cleanup |
| **`packages/swift/ThinAppViewCore`** | Shared indexing, storage, worker runtime |

Gateway→AppView trust uses **`GATEWAY_APPVIEW_INTERNAL_SECRET`** (HMAC on path only). Clients always call the gateway host.

## Data flow

```
Relay / Jetstream (subscribeRepos)
        │
        ▼
Fly appview-worker
  • upsert content_items (title, publishedAt, summary, thumbnail ref)
  • mirror entryReadState → read_marks
  • proactive PDS backfill for subscribed authors
  • TTL cleanup
        │
        ▼
Supabase Postgres (ams) — content_items, read_marks, sidebar_projection_cache, …
        │
        ▼
Fly appview — bootstrap-stream, /v1/appview/*, /v1/publications/*
        │
        ▼
Fly gateway — OAuth, proxy (no buffering on bootstrap-stream)
        │
        ├── Web (`NEXT_PUBLIC_USE_THIN_APPVIEW`)
        └── iOS (`SOCIALWIRE_USE_THIN_APPVIEW` compile flag)
```

## Initial load

Authenticated **`GET /v1/appview/bootstrap-stream`** returns NDJSON events as sidebar priority rows, unread counts, first-unread publication selection, first feed page, and folder sections complete. Web and iOS consume the same contract. Cache-first repeat visits paint persisted projection cache while the stream refreshes.

## Consistency model

- **Writes:** PDS first, then best-effort write-through to the index (`POST/DELETE /v1/appview/read-marks`).
- **Ingestion:** Firehose + enrollment backfill (`POST /v1/appview/enroll`) + worker proactive backfill.
- **Unread UI:** Local optimistic read state remains primary; the index enables server-side unread pagination and sidebar badges merged with local/PDS read state.

## Privacy & retention

- **Region:** Fly + Supabase in **`ams`** (EU).
- **Level 1 only:** No full HTML bodies or blobs in the index.
- **TTL defaults:** `content_items` 30 days; `read_marks` 180 days (env-configurable).
- **User control:** `DELETE /v1/appview/privacy/purge` removes indexed read marks for the authenticated viewer.

## Feature flags

| Surface | Flag |
|---------|------|
| AppView routes + worker | `ENABLE_THIN_APPVIEW` |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW=true` |
| iOS client | `SOCIALWIRE_USE_THIN_APPVIEW` (Swift compile condition) |

When flags are off, clients continue PDS-direct `listRecords` entry loading.

## Future cross-user index

A separate, fuller AppView may still be added later for cross-user features (popular among follows, public folder indexes, federated discovery). That scope is **not** part of the thin AppView. See historical notes in git history for the original Phase 1 deferral rationale.
