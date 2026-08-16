# Web test plan

**Package:** `apps/web`  
**Runner:** Bun test (`bunfig.toml` — jsdom, preload `src/__tests__/setup.ts`)  
**CI:** `web` → typecheck, lint, Bun tests, and Next.js production build

## Commands

```bash
cd apps/web
bun test              # all tests
bun test --coverage   # optional local coverage report
```

## Test layout

```
apps/web/src/__tests__/
  *.test.ts(x)        # libraries and targeted components
  hooks/*.test.tsx    # React hook tests (Testing Library renderHook)
  api/*.test.ts       # Next.js route handler tests
  contexts/*.test.tsx # reader/sidebar state providers
  mocks/              # MSW server + handlers
```

## Coverage inventory

The suite is intentionally colocated and grows with the owning code. Representative areas:

| Area | Examples |
|------|----------|
| Auth and OAuth | `auth`, scopes, client metadata, callback/session expiry |
| AppView reader | bootstrap state, feeds/detail, pagination, prefetch, unread counts, optimistic read state |
| Sidebar/publications | projection client/provider, discovery compatibility, folders, subscriptions, tabs, persistence |
| L@tr | gateway proxy/DPoP, saves and metadata backfill, archive/open targets, saved-link social/publication resolution |
| Article presentation | sanitization, oEmbed/iframe policies, canonical URLs, reader-mode selection, thumbnails |
| Components/contexts | entry rows/actions, sidebar/header/navigation, appearance, tabs, ReadRoute context |

## API routes (`src/app/api/`)

| Route | Test file |
|-------|-----------|
| `oauth/web-client-metadata` | `api/web-client-metadata.test.ts` |
| `rss-feed` | `api/rss-feed.test.ts` |
| `embed-frame` | `api/embed-frame.test.ts` |
| `oembed` | `api/oembed.test.ts` |
| `bluesky-card-thumb` | `api/bluesky-card-thumb.test.ts` |
| `latr-gateway/[...path]` | `api/latr-gateway.test.ts` |

## Components

Targeted components are tested with Testing Library. Responsive layout, browser navigation, and full OAuth/PDS/AppView interaction still require manual verification.

## MSW

Network mocks live in `src/__tests__/mocks/`. Handlers mirror gateway and PDS XRPC shapes used by hooks and lib tests.

## Lexicons

Schema validation tests live in `packages/lexicons/__tests__/`. CI job: **`lexicons`**. See [README](../../packages/lexicons/README.md).

## Manual verification

- [ ] Sign in with loopback OAuth on `localhost`
- [ ] Sign in on Railway Development through `testing.thesocialwire.app`; confirm the client ID is its same-origin `/oauth-client-metadata.json` and returns to `/callback`
- [ ] Confirm Production metadata and redirects remain on `thesocialwire.app`, and neither environment publishes a generated `*.up.railway.app` OAuth identity
- [ ] Subscribe to a publication (standard.site or RSS)
- [ ] Mark entry read/unread; confirm sidebar badges
- [ ] Bootstrap, aggregate/scoped feeds, and flat entry detail load through the gateway
- [ ] `/saved` and `/archive` load L@tr items and keep archive/delete state consistent
