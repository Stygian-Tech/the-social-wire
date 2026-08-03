# Publication Discovery

## Overview

With **Thin AppView** enabled (the default production path), publication discovery and sidebar assembly happen **server-side** via AppView:

- **`GET /v1/appview/bootstrap-stream`** — progressive NDJSON for initial reader load
- **`GET /v1/publications/sidebar`** — full or phased sidebar JSON (`phase=full|priority|folderPublications`)
- **`POST /v1/publications/refresh`** — force recompute after subscription changes

The projection merges follow-graph discovery, graph subscriptions, Skyreader RSS rows, folder prefs, and per-publication AppView scope keys. Clients paint folder/publication headers immediately and fill rows as stream events arrive.

## Legacy and diagnostic client-side discovery

The web codebase retains direct author-PDS discovery helpers for diagnostics and compatibility probes, but current feed/detail hooks require AppView rather than providing a complete fallback:

1. Fetch follows via `app.bsky.graph.getFollows` (public App View) merged with PDS graph
2. Check each followed DID for `site.standard.publication`, `site.standard.document`, and legacy entry collections
3. Cache results in React Query / SwiftData

```
GET https://{author-pds}/xrpc/com.atproto.repo.listRecords
  ?repo={did}
  &collection=site.standard.document
  &limit=1
```

Profile metadata comes from `app.bsky.graph.getFollows` and `app.bsky.actor.getProfile`.

## Concurrency

Legacy client probes batch followed DID checks (web: settled promises; older iOS paths used Swift task groups).

When Thin AppView is enabled, web and iOS call **`POST /v1/appview/enroll`** with author DIDs after sidebar load (best-effort backfill). Charybdis (`appview-worker`) also runs **proactive PDS backfill** on a timer for subscribed authors.

## AppView layers

Social Wire uses **two** AppView concepts:

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | `getFollows`, `getProfile`, handle resolution | In use — unchanged |
| **Thin AppView** (`/v1/appview/*` on **`services/appview`**) | Entry timelines/detail + sidebar projection + server-side unread | Current client read path; server feature-gated |

A **future cross-user indexer** (popular among follows, public folder indexes, federated discovery via firehose) is a separate scope — not the thin AppView. See [appview.md](appview.md).
