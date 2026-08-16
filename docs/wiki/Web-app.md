# Web app

The production web reader is [thesocialwire.app](https://thesocialwire.app). It supports desktop and mobile layouts with the same four lists described in [[Getting-started]].

## Web-only capabilities

The web client currently includes several controls that are not exposed in the Apple client:

- System, Light, and Dark themes;
- Sans, Serif, and Mono reader fonts plus Bold Text;
- an RSS **Open in Reader** preference;
- standard.site **Recommend** actions where supported; and
- a public UserInput feedback form with optional images.

Like, Reply, and Repost require a compatible Bluesky post linked to the article. **Post** can create a new post when no linked post exists.

## Routes

- `/read` — Subscribed, Following, folders, publications, and articles
- `/saved` — active L@tr Link queue
- `/archive` — archived saved links
- `/me` — My Publications and account settings
- `/login` and `/callback` — ATProto OAuth

`/saved/settings` is a compatibility redirect to `/saved`; there is no read-later provider selector.

## Developer setup

The Next.js client lives under `apps/web` and uses Bun.

```bash
bun install
cd apps/web
cp .env.example .env.local
bun run dev
```

Open [http://localhost:3000](http://localhost:3000). Local `next dev` uses ATProto's parameterized loopback OAuth client; it does not bypass OAuth or require committed secrets.

The full setup, environment, and OAuth reference is [apps/web/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/README.md).

## Data sources

| Data | Current path |
|------|--------------|
| Initial load | `GET /v1/appview/bootstrap-stream` NDJSON |
| Sidebar refresh and resolve | Hosted `/xrpc/app.thesocialwire.publication.*` methods |
| Folders, preferences, subscriptions | Direct viewer-PDS writes through the OAuth session |
| Entry lists and detail | Hosted `/xrpc/app.thesocialwire.appview.*` methods |
| Read state | Browser local storage for immediate UI plus AppView read marks/floors |
| Read Later and Archive | Same-origin `/api/latr-gateway/xrpc/link.latr.bookmarks.*` backed by L@tr Link |

Current web and Apple clients do not create `app.thesocialwire.entryReadState` records. Cross-client refresh asks AppView for current unread baselines.

## Important modules

| Module | Role |
|--------|------|
| `PublicationSidebarProvider` / `usePublicationSidebarData` | Bootstrap stream and sidebar projection state |
| `useEntries` | AppView publication and aggregate infinite queries |
| `useProactiveFeedRefresh` | Visible-feed background and focus refresh |
| `thinAppViewClient.ts` | AppView feed, detail, unread, mutation, enrollment, and purge client |
| `publicationProjectionClient.ts` | Publication projection client |
| `pdsClient.ts` | Viewer-PDS folders, preferences, subscriptions, and legacy migration compatibility |
| `entryReadStateStorage.ts` | Browser-local optimistic read map |

Persisted browser caches include a bounded TanStack Query snapshot in IndexedDB, local read state, sidebar expansion state scoped by viewer DID, and a local image blob cache. They contain no OAuth secrets and are rebuildable.

## Environment

| Environment | Web | Gateway |
|-------------|-----|---------|
| Development | `https://testing.thesocialwire.app` | `https://api.testing.thesocialwire.app` |
| Production | `https://thesocialwire.app` | `https://api.thesocialwire.app` |

Set `NEXT_PUBLIC_APP_ENV`, `NEXT_PUBLIC_SITE_URL`, and `NEXT_PUBLIC_SOCIALWIRE_API_URL` from the same row. Hosted OAuth metadata is same-origin. Generated Railway domains must not be used as public OAuth identities.

## Verification

```bash
cd apps/web
bun test
bun run typecheck
bun run lint
bun run build
```

See [[Testing]] and the [web test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md).

Related: [[Reading-and-organizing]], [[Read-Later-and-Archive]], [[Service-API]], [[Thin-AppView]].
