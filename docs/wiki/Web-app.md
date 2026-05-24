# Web app

Next.js client under `apps/web`.

**Setup and internals**

- [apps/web/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/README.md)

Includes ATProto OAuth (hosted vs loopback dev), PDS vs Bluesky App View usage, env vars, and testing commands.

## Data sources (Thin AppView path — default when flag on)

| Data | Path |
|------|------|
| **Initial load** | `GET /v1/appview/bootstrap-stream` (NDJSON) — sidebar slices, unread counts, first-unread selection, first feed page |
| Sidebar refresh / resolve | `GET/POST /v1/publications/sidebar|refresh|resolve` via `publicationProjectionClient` |
| Folders, prefs, subscriptions | Gateway write-through → viewer PDS (`socialWireGatewayClient`) |
| Entry **lists** | `GET /v1/appview/entries` via `useEntries` / `thinAppViewClient` |
| Entry **detail** | Author PDS `getRecord` (always PDS-direct) |
| Read state | Dual-write: viewer PDS + AppView read marks; local `the-social-wire.read-state.v1` for optimistic UI |
| Mark all read | `POST /v1/appview/mark-all-read` (scoped) + PDS bulk write |

## Thin AppView (optional)

Enable when gateway, appview, and appview-worker are deployed and Supabase migrations are applied:

```bash
# apps/web/.env.local
NEXT_PUBLIC_USE_THIN_APPVIEW=true
NEXT_PUBLIC_SOCIALWIRE_API_URL=https://api.thesocialwire.app
```

| Module | Role |
|--------|------|
| `usePublicationSidebarData` | Bootstrap stream + sidebar projection cache |
| `useEntries` | Entry list infinite query (AppView or PDS fallback) |
| `useProactiveFeedRefresh` | Background/refocus refresh of active publication feed |
| `lib/feedRefresh.ts` | Merge first-page refresh without invalidating pagination |
| `lib/thinAppViewClient.ts` | AppView entries, unread counts, read marks, enroll |
| `lib/publicationProjectionClient.ts` | Sidebar JSON client |
| `lib/pdsClient.ts` | PDS XRPC + read-state sync |

**Proactive feed refresh:** while a publication is open and the tab is visible, the client periodically refetches the first feed page and merges new rows (post-bootstrap enroll runs once; ongoing polls skip enroll).

Local optimistic read state remains primary for UI; the index enables server-side unread pagination and sidebar badges merged with local/PDS read state.

See [[Thin-AppView]].

## Testing

Unit tests: `cd apps/web && bun test` (CI: `build-web`).

| Area | Coverage |
|------|----------|
| `src/lib/` | All modules — see [test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) |
| `src/hooks/` | Entries, sidebar, bootstrap stream, proactive refresh, read-later |
| `src/app/api/` | Route handler tests |
| `src/components/` | Manual browser verification only |

See [[Testing]].

## Related

- Example env: [apps/web/.env.example](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/.env.example)
- Hosted OAuth metadata: [client-metadata.json](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/public/client-metadata.json)
- [[Service-API]] — gateway + appview routes and deployment
