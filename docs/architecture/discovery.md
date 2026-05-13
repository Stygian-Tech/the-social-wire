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

## AppView (future)

If cross-user discovery features are needed (e.g., "popular publications among your followed accounts"), a firehose-based AppView can be added:

- Subscribes to `com.atproto.sync.subscribeRepos` firehose
- Indexes `com.thesocialwire.*` records from across the network
- Exposes XRPC-style query endpoints: `com.thesocialwire.getFolders`, etc.

Phase 1 defers this — clients handle per-user discovery without cross-user indexing.
