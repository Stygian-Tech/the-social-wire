# Web app

Next.js client under `apps/web`.

**Setup and internals**

- [apps/web/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/README.md)

Includes ATProto OAuth (hosted vs loopback dev), PDS vs Bluesky App View usage, env vars, and testing commands.

## Data sources

| Data | Path |
|------|------|
| **Initial load** | `GET /v1/appview/bootstrap-stream` (NDJSON) — sidebar slices, unread counts, first-unread selection, first feed page |
| Sidebar refresh / resolve | `GET/POST /v1/publications/sidebar|refresh|resolve` via `publicationProjectionClient` |
| Folders, prefs, subscriptions | Direct viewer-PDS writes through `PDSClient`; sidebar reads come from the gateway projection |
| Entry **lists** | `GET /v1/appview/feed` for aggregate/current feeds; `GET /v1/appview/entries` for scoped publication rows and prefetches |
| Entry **detail** | `GET /v1/appview/entry`; a narrow author-PDS read may recover a missing original/embed URL |
| Read state | Local `the-social-wire.read-state.v1` for optimistic UI + AppView read marks |
| Mark all read | `POST /v1/appview/mark-all-read` (scoped read floor/counter update) |

## AppView read path

The current reader requires the gateway, AppView, worker, and database migrations. The web switch defaults on; explicitly setting it to `false` is only useful when diagnosing a deployment without AppView routes:

```bash
# apps/web/.env.local
NEXT_PUBLIC_USE_THIN_APPVIEW=true
NEXT_PUBLIC_SOCIALWIRE_API_URL=https://api.thesocialwire.app
```

| Module | Role |
|--------|------|
| `usePublicationSidebarData` | Bootstrap stream + sidebar projection cache |
| `useEntries` | AppView publication/aggregate infinite queries and flat entry detail |
| `useProactiveFeedRefresh` | Background/refocus refresh of active publication feed |
| `lib/feedRefresh.ts` | Merge first-page refresh without invalidating pagination |
| `lib/thinAppViewClient.ts` | AppView entries, unread counts, read marks, enroll |
| `lib/publicationProjectionClient.ts` | Sidebar JSON client |
| `lib/pdsClient.ts` | Direct viewer-PDS XRPC for folders, preferences, subscriptions, and local L@tr assembly/fallbacks |

**Proactive feed refresh:** while a publication is open and the tab is visible, the client periodically refetches the first feed page and merges new rows (post-bootstrap enroll runs once; ongoing polls skip enroll).

Local optimistic read state remains primary for UI; AppView enables server-side unread pagination and sidebar badges.

See [[Thin-AppView]].

## Read Later and Archive

`/saved` and `/archive` are sibling destinations using the same three-pane reader shell. `/saved/settings` redirects to `/saved`; the UI does not offer a read-later provider selector. L@tr Link is the default: lists use the same-origin `/api/latr-gateway` proxy, and mutations use that proxy with the direct-PDS fallbacks implemented by the web provider.

## Testing

Unit tests: `cd apps/web && bun test` (CI: `build-web`).

| Area | Coverage |
|------|----------|
| `src/lib/` | Broad helper coverage — see [test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) |
| `src/hooks/` | Entries, sidebar, bootstrap stream, proactive refresh, read-later |
| `src/app/api/` | Route handler tests |
| `src/components/` | Targeted component tests plus manual browser verification |

See [[Testing]].

## Related

- Example env: [apps/web/.env.example](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/.env.example)
- Hosted OAuth metadata: [client-metadata.json](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/public/client-metadata.json)
- [[Service-API]] — gateway + appview routes and deployment
