# AppView (future)

## When would we need one?

Phase 1 avoids a dedicated AppView. The per-user discovery service handles finding publications by traversing each user's follow graph independently. This is sufficient for:

- Showing a user's personalised publication list
- Entry feeds and content delivery

An AppView becomes necessary only if we need **cross-user indexing**:

| Feature | Needs AppView? |
|---------|---------------|
| My publication list | No — derived from my follows |
| Reading entries | No — fetched per-publication |
| "Popular among my follows" | Yes — requires cross-user data |
| Other users' public folder lists | Yes — requires indexing others' PDS records |
| Federated publication discovery | Yes — requires firehose subscription |

## Architecture if added

```
ATProto firehose (com.atproto.sync.subscribeRepos)
       │
       ▼
AppView subscriber (Go or Swift)
  Filters: com.thesocialwire.* events
  Indexes into Supabase:
    - public_folders (user_did, folder_name, ...)
    - public_pub_prefs (user_did, publication_id, folder_id, ...)
       │
       ▼
New XRPC-style query endpoints:
  com.thesocialwire.getFolders?actor={did}
  com.thesocialwire.getPublicationPrefs?actor={did}
```

## Implementation notes

- The AppView should be a separate service (`services/appview/`) to keep the existing API service focused on per-user discovery and content
- Endpoints should follow the ATProto XRPC naming convention so other clients can use them
- The firehose subscriber can use `Postgres NOTIFY` / Supabase Realtime to push updates to connected clients
- All indexed data is **public** — `com.thesocialwire.*` records on a user's PDS are readable by anyone with the DID

## Decision

Phase 1 defers the AppView. Revisit if:
1. Discovery quality requires cross-user signals
2. Social features (sharing reading lists, following readers) are prioritised
3. The standard.site ecosystem grows to a scale where a global index is valuable
