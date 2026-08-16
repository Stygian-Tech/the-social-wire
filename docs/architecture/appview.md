# AppView architecture

> **Wiki summary:** [docs/wiki/Thin-AppView.md](../wiki/Thin-AppView.md). The
> checked-in wiki is synced to GitHub Wiki from `main` and published separately
> to Lichen.

Social Wire uses two distinct “AppView” concepts:

> **Release status:** the current checkout adds the Social Wire XRPC aliases
> described below, but public Testing and Production still return `404` for them
> as of 2026-08-12. The deployed read path continues to use the retained
> `/v1/*` routes until the backend and clients ship together.

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | Public social graph reads (`getProfile`, `getFollows`, …) | Unchanged — clients call it directly |
| **Thin AppView** (hosted `/v1/appview/*`; pending source adds `/xrpc/app.thesocialwire.appview.*`, proxied by **`services/gateway`**) | Data-minimized entry timelines, indexed detail, sidebar projection, server-side unread filtering | Deployed read path; server remains feature-gated |

The thin AppView is **not** a Bluesky proxy. It is Social Wire’s own index of `standard.site` entry collections, parsed Skyreader RSS entries, and AppView-owned `read_marks` for unread queries. Standard.site records remain authoritative on each author’s PDS; RSS rows may retain content HTML supplied by the feed. Feed read/unread state is local-first in clients and synchronized to Social Wire AppView, not written as ATProto repo records.

## Distributed services

| Service | Responsibility |
|---------|----------------|
| **`services/gateway`** | Public OAuth/DPoP edge, PDS write-through, sync cache, unbuffered proxy to AppView |
| **`services/appview`** | Hosted `/v1/*` routes and bootstrap stream; pending source adds Sidebar/AppView XRPC aliases; projection cache |
| **Charybdis** (`services/appview-worker`) | Jetstream/Tap ingestion, Skyreader RSS polling, proactive PDS backfill, TTL cleanup |
| **`packages/swift/ThinAppViewCore`** | Shared indexing, storage, worker runtime |

Gateway→AppView trust uses **`GATEWAY_APPVIEW_INTERNAL_SECRET`** (HMAC on path only). Clients always call the gateway host.

## Data flow

```
Relay / Jetstream (subscribeRepos)
        │
        ▼
Railway Charybdis (`appview-worker` source directory)
  • consume Jetstream or environment-scoped Tap
  • poll enrolled Skyreader RSS feed URLs
  • upsert content_items (title, publishedAt, summary, thumbnail ref)
  • proactive PDS backfill for subscribed authors
  • TTL cleanup
        │
        ▼
Railway Postgres — content_items, read marks/floors, materialized counters, ingestion/repair state
        │
Optional private Railway Redis — currently selected for hosted cache/lease work in Development and Production
        │
        ▼
Railway AppView — hosted bootstrap-stream + /v1/*; pending /xrpc/app.thesocialwire.* aliases
        │
        ▼
Railway Gateway — OAuth, proxy (no buffering on bootstrap-stream)
        │
        ├── Web (`NEXT_PUBLIC_USE_THIN_APPVIEW`)
        └── iOS (`SOCIALWIRE_USE_THIN_APPVIEW` compile flag)
```

## Initial load

Authenticated **`GET /v1/appview/bootstrap-stream`** returns NDJSON events as sidebar priority rows, per-folder `sidebarSection` slices, unread counts, first-unread publication selection, first feed page, and a legacy `sidebarFolders` payload for older clients. Web and iOS consume the same contract. Cache-first repeat visits paint persisted projection cache while the stream refreshes. Eligible non-streaming JSON calls use Lexicon-defined `/xrpc/app.thesocialwire.*` methods; `/v1/*` aliases remain for compatibility and OpenAPI documentation.

Hosted cache behavior and rollout are documented in [redis.md](redis.md).
Postgres cache tables are active wherever Redis is not selected and are the
rollback target for an environment in Redis mode. SQLite stores remain useful in
package tests, but the current service entry points reject `APP_ENV=local`; local
service integration therefore uses an isolated disposable Postgres database.

## Consistency model

- **Writes:** clients update local read state immediately, then call `app.thesocialwire.appview.putReadMark`, `deleteReadMark`, or `markAllRead` (with `/v1/*` compatibility aliases).
- **Ingestion:** Jetstream/Tap + enrollment backfill (`authorDids`) + immediate RSS ingestion (`feedUrls`) + worker proactive backfill/polling.
- **Unread UI:** Local optimistic read state remains primary for instant row state; AppView enables server-side unread pagination and sidebar badges.

## Privacy & retention

- **Region:** compute and Postgres placement are Railway environment settings. Verify those settings directly before making data-residency claims.
- **Data-minimized index:** standard.site indexing extracts render/detail fields rather than blobs or complete repo records; RSS ingestion may retain the feed-provided HTML body.
- **TTL defaults:** `content_items` 30 days; `read_marks` 180 days (env-configurable).
- **User control:** `POST /xrpc/app.thesocialwire.appview.purgeViewerData` removes explicit `read_marks` and `appview_unread_overrides` for the authenticated viewer. Bulk-read floors and other projection rows remain.
- **Authority:** user-authored organization and preference records remain on the user's PDS; AppView projections are rebuildable.

## Feature flags

| Surface | Flag |
|---------|------|
| AppView routes + worker | `ENABLE_THIN_APPVIEW` |
| Web client | `NEXT_PUBLIC_USE_THIN_APPVIEW` (enabled unless explicitly `false`) |
| iOS client | AppView routes are used when available; `SOCIALWIRE_USE_THIN_APPVIEW` currently gates the Profile purge action |

Turning off the server flag removes the AppView read routes. Current clients do not provide a complete PDS-direct feed/detail fallback, so this is a diagnostic or rollback control for the service—not an alternate production client mode.

## Future cross-user index

A separate, fuller AppView may still be added later for cross-user features (popular among follows, public folder indexes, federated discovery). That scope is **not** part of the thin AppView. See historical notes in git history for the original Phase 1 deferral rationale.
