# Web test plan

**Package:** `apps/web`  
**Runner:** Bun test (`bunfig.toml` — jsdom, preload `src/__tests__/setup.ts`)  
**CI:** `build-web` → `turbo test --filter=web`

## Commands

```bash
cd apps/web
bun test              # all tests
bun test --coverage   # optional local coverage report
```

## Test layout

```
apps/web/src/__tests__/
  *.test.ts           # lib module tests
  hooks/*.test.tsx    # React hook tests (Testing Library renderHook)
  api/*.test.ts       # Next.js route handler tests
  mocks/              # MSW server + handlers
```

## Module inventory (`src/lib/`)

| Module | Test file | Status |
|--------|-----------|--------|
| `appEnv.ts` | `appEnv.test.ts` | Covered |
| `atprotoClient.ts` | `atprotoClient.*.test.ts` | Covered |
| `addPublicationResolveServer.ts` | `addPublicationResolveServer.test.ts` | Covered |
| `embedFramePolicy.ts` | `embedFramePolicy.test.ts` | Covered |
| `entryArticleFilter.ts` | `entryArticleFilter.test.ts` | Covered |
| `entryReadStateStorage.ts` | `entryReadStateStorage.test.ts` | Covered |
| `latrSavedUrls.ts` | `latrSavedUrls.test.ts` | Covered |
| `oauthClientMetadata.ts` | `oauthClientMetadata.test.ts` | Covered |
| `oauthSessionSignals.ts` | `oauthSessionSignals.test.ts` | Covered |
| `pdsClient.ts` | `pdsClient.test.ts` | Covered |
| `publicResourceUrl.ts` | `publicResourceUrl.test.ts` | Covered |
| `rssFeedCore.ts` | `rssFeedCore.test.ts` | Covered |
| `rssFeedServer.ts` | `rssFeedServer.test.ts` | Covered |
| `sanitize.ts` | `sanitize.test.ts` | Covered |
| `thinAppViewClient.ts` | `thinAppViewClient.test.ts` | Covered |
| `feedRefresh.ts` | `feedRefresh.test.ts` | Covered |
| `unreadCounts.ts` | `unreadCounts.test.ts` | Covered |
| `auth.ts` | `auth.test.ts`, `pathnameIsOAuthCallbackRoute.test.ts` | Covered |
| `publicationSubscriptionMatch.ts` | `publicationSubscriptionMatch.test.ts` | Covered |
| `readLaterServices.ts` | `readLaterServices.test.ts` | Covered |
| `articleCanonicalUrl.ts` | `articleCanonicalUrl.test.ts` | Covered |
| `atprotoOAuthScopes.ts` | `atprotoOAuthScopes.test.ts` | Covered |
| `utils.ts` | — | Trivial helpers; covered indirectly |

## Hooks (`src/hooks/`)

| Hook | Test file | Status |
|------|-----------|--------|
| `useEntries.ts` | `hooks/useEntries.test.tsx` | Covered |
| `usePublications.ts` (useDiscovery) | `hooks/useDiscovery.test.tsx` | Partial |
| `useSidebarUnreadCounts.ts` | `hooks/useSidebarUnreadCounts.test.tsx` | Covered |
| `useCachedBulkReadActions.ts` | `hooks/useCachedBulkReadActions.test.tsx` | Covered |
| `usePublicationSidebarData.ts` | `hooks/usePublicationSidebarData.test.tsx` | Covered |
| `useProactiveFeedRefresh.ts` | — | Covered via `feedRefresh.test.ts` |
| `useReadLaterPreferences.ts` | `hooks/useReadLaterPreferences.test.tsx` | Covered |
| `useLatrSaved.ts` | `hooks/useLatrSaved.test.tsx` | Covered |
| `usePublications.ts` | `hooks/usePublications.test.tsx` | Covered |

## API routes (`src/app/api/`)

| Route | Test file |
|-------|-----------|
| `oauth/web-client-metadata` | `api/web-client-metadata.test.ts` |
| `resolve-add-publication` | `api/resolve-add-publication.test.ts` |
| `rss-feed` | `api/rss-feed.test.ts` |
| `embed-frame` | `api/embed-frame.test.ts` |

## Components

UI components under `src/components/` are **not** unit-tested. Verify layout and interactions manually in the browser.

## MSW

Network mocks live in `src/__tests__/mocks/`. Handlers mirror gateway and PDS XRPC shapes used by hooks and lib tests.

## Lexicons

Schema validation tests live in `packages/lexicons/__tests__/`. CI job: **`test-lexicons`**. See [README](../../packages/lexicons/README.md).

## Manual verification

- [ ] Sign in with loopback OAuth on `localhost`
- [ ] Subscribe to a publication (standard.site or RSS)
- [ ] Mark entry read/unread; confirm sidebar badges
- [ ] Thin AppView flag: entry list loads from gateway when enabled
