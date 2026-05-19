# Publication Discovery

## Overview

When the user triggers a discovery refresh, the client:

1. Fetches the user's follow graph through public ATProto XRPC
2. Checks each followed DID for `site.standard.entry` records
3. Caches the result in client query/view state

## Discovery Chain

The v1 client discovery signal is intentionally direct: a followed DID is a publication if it has at least one standard.site entry record.

```
GET https://bsky.social/xrpc/com.atproto.repo.listRecords
  ?repo={did}
  &collection=site.standard.entry
  &limit=1
```

Profile metadata comes from `app.bsky.graph.getFollows`, so the UI can show handles, display names, and avatars without a Social Wire service.

```
GET https://bsky.social/xrpc/app.bsky.graph.getFollows
  ?actor={userDid}
  &limit=100
```

## Concurrency

Clients batch followed DID checks to keep refresh latency reasonable without sending unbounded concurrent requests. Web uses settled promises; Apple uses Swift task groups.

When Thin AppView is enabled, web and iOS call **`POST /v1/appview/enroll`** with unique author DIDs after discovery completes (best-effort backfill).

## AppView layers

Social Wire uses **two** AppView concepts:

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | `getFollows`, `getProfile`, handle resolution | In use — unchanged |
| **Thin AppView** (`/v1/appview/*` on `services/api`) | Level-1 entry timelines + server-side unread | Optional, feature-flagged |

A **future cross-user indexer** (popular among follows, public folder indexes, federated discovery via firehose) is a separate scope — not the thin AppView. See [appview.md](appview.md).
