# AppView architecture

> **Wiki summary:** [docs/wiki/Thin-AppView.md](../wiki/Thin-AppView.md) (synced to GitHub Wiki on push to **`main`** when `docs/wiki/**` changes).

Social Wire uses two distinct “AppView” concepts:

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | Public social graph reads (`getProfile`, `getFollows`, …) | Unchanged — clients call it directly |
| **Thin AppView** (`/v1/appview/*` on **`services/appview`**, proxied by **`services/gateway`**) | Data-minimized Level-1 entry timelines, sidebar projection, server-side unread filtering | Implemented behind feature flags |

The thin AppView is **not** a Bluesky proxy. It is Social Wire’s own index of `standard.site` entry collections plus AppView-owned `read_marks` for unread queries. Full entry bodies remain on each author’s PDS; feed read/unread state is local-first in clients and synchronized to Social Wire AppView, not written as ATProto repo records.

## Distributed services

| Service | Responsibility |
|---------|----------------|
| **`services/gateway`** | Public OAuth/DPoP edge, PDS write-through, sync cache, unbuffered proxy to AppView |
| **`services/appview`** | Sidebar projection (`/v1/publications/*`), Thin AppView reads (`/v1/appview/*`), bootstrap stream, projection caches |
| **Charybdis** (`services/appview-worker`) | Jetstream ingestion, proactive PDS backfill, TTL cleanup |
| **`packages/swift/ThinAppViewCore`** | Shared indexing, storage, worker runtime |

Gateway→AppView trust uses **`GATEWAY_APPVIEW_INTERNAL_SECRET`** (HMAC on path only). Clients always call the gateway host.

## Data flow

```
Relay / Jetstream (subscribeRepos)
        │
        ▼
Fly Charybdis (`appview-worker` compatibility identity)
  • upsert content_items (title, publishedAt, summary, thumbnail ref)
  • proactive PDS backfill for subscribed authors
  • TTL cleanup
        │
        ▼
Supabase Postgres (AWS us-east-1) — content_items, read_marks, sidebar_projection_cache, …
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

Authenticated **`GET /v1/appview/bootstrap-stream`** returns NDJSON events as sidebar priority rows, per-folder `sidebarSection` slices, unread counts, first-unread publication selection, first feed page, and a legacy `sidebarFolders` payload for older clients. Web and iOS consume the same contract. Cache-first repeat visits paint persisted projection cache while the stream refreshes.

## Consistency model

- **Writes:** clients update local read state immediately, then write AppView read marks (`POST/DELETE /v1/appview/read-marks`) or scoped read floors (`POST /v1/appview/mark-all-read`).
- **Ingestion:** Firehose + enrollment backfill (`POST /v1/appview/enroll`) + worker proactive backfill.
- **Unread UI:** Local optimistic read state remains primary for instant row state; AppView enables server-side unread pagination and sidebar badges.

## Privacy & retention

- **Region:** all Fly compute is in **`iah`**; Supabase/Postgres remains in AWS **`us-east-1`**. Data residency is the United States.
- **Level 1 only:** No full HTML bodies or blobs in the index.
- **TTL defaults:** `content_items` 30 days; `read_marks` 180 days (env-configurable).
- **User control:** `DELETE /v1/appview/privacy/purge` removes indexed read marks for the authenticated viewer.
- **Authority:** user-authored organization and preference records remain on the user's PDS; AppView projections are rebuildable.

## Feature flags

| Surface | Flag |
|---------|------|
| AppView routes + worker | `ENABLE_THIN_APPVIEW` |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW=true` |
| iOS client | `SOCIALWIRE_USE_THIN_APPVIEW` (Swift compile condition) |

When flags are off, clients continue PDS-direct `listRecords` entry loading.

## Future cross-user index

A separate, fuller AppView may still be added later for cross-user features (popular among follows, public folder indexes, federated discovery). That scope is **not** part of the thin AppView. See historical notes in git history for the original Phase 1 deferral rationale.
