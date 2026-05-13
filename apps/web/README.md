# The Social Wire — Web

Next.js 16.2+ web client for The Social Wire, built with Bun.

## Prerequisites

- [Bun](https://bun.sh) ≥ 1.2
- Node.js ≥ 22 (for shadcn/ui compatibility)
- An ATProto account (Bluesky or any PDS)

## Quick Start

```bash
# From the monorepo root
bun install

# Start the dev server
cd apps/web
bun run dev
```

The app runs at [http://localhost:3000](http://localhost:3000).

## Environment Variables

Copy `.env.example` to `.env.local` and fill in:

| Variable | Description |
|----------|-------------|
| `NEXT_PUBLIC_APP_ENV` | `prod` / `dev` / `local` — controls the environment banner |
| `NEXT_PUBLIC_ATPROTO_CLIENT_ID` | OAuth client ID (URL of `client-metadata.json`) |

## Architecture

### Auth

Authentication uses ATProto OAuth (PKCE + DPoP) via `@atproto/oauth-client-browser`.

- `src/lib/auth.ts` — OAuth client setup, signIn redirect, callback handling, session restore
- `src/hooks/useAuth.tsx` — `AuthProvider` context; exposes `session.did`, `getAuthFetch()`, `getOAuthSession()`
- `src/lib/pdsClient.ts` — XRPC helpers for reading/writing ATProto records on the user's PDS (`new Agent(oauthSession)`)
- `src/lib/atprotoClient.ts` — public ATProto XRPC helpers for discovery and standard.site entry reads

### Data Flow

```
User's PDS (OAuth session — canonical for repo + graph on the viewer's repo)
  └─ com.thesocialwire.folder           ← useFolders / useCreateFolder
  └─ com.thesocialwire.publicationPrefs ← usePublicationPrefs / useSetPublicationFolder
  └─ app.bsky.graph.follow              ← discoverPublications (canonical follow subjects)

Author repos (PLC-resolved PDS; com.atproto.repo.* — not the App View relay)
  └─ site.standard.publication, com.standard.publication  ← discovery probes (first)
  └─ site.standard.document, com.standard.document       ← discovery + entry listing
  └─ site.standard.entry, com.standard.entry             ← discovery + entry listing (legacy entry NSIDs)

Public App View (https://public.api.bsky.app — no OAuth on these calls)
  └─ com.atproto.identity.resolveHandle
  └─ app.bsky.graph.getFollows         ← merged with PDS graph when under cap
  └─ app.bsky.actor.getProfile         ← follow enrichment (useViewerProfile also uses repo profile fallback)
```

All user organisation data (folders, publication prefs) is stored on the user's own PDS — not in the Social Wire backend. Entry bodies and discovery probes read **authors' records from their PDS endpoints**, not from a Social Wire API (see also `packages/spec/openapi.yaml` for the separate caching service used elsewhere in the monorepo).

#### PDS-first reads vs public App View

OAuth access tokens are **audience-bound to the user's PDS**, not to the Bluesky App View. The web app uses a session-backed `@atproto/api` `Agent` for `com.atproto.repo.*` on the viewer's repo and on followed authors' repos (`atprotoClient.ts`). For **identity and graph helpers**, it uses `https://public.api.bsky.app` with plain `fetch` / a non-OAuth `Agent` — e.g. extra follow edges via `app.bsky.graph.getFollows`, handle resolution, and profile enrichment. **Do not rely on the App View relay for `com.atproto.repo.*` on `site.standard.*` / `com.standard.*` collections**; those reads target each author's PDS and may fail or 400 when attempted through the wrong host.

### Lexicons & collections

Lexicon **collection** (NSID) strings used in the web client match `apps/web/src/lib/atprotoClient.ts` and `apps/web/src/lib/pdsClient.ts`:

| Collection | Role in the web app |
|------------|---------------------|
| `site.standard.publication` | Discovery: publication-shaped records probed first for sidebar titles |
| `com.standard.publication` | Discovery: alternate publication collection |
| `site.standard.document` | Discovery fallback; primary document collection for **entry lists** (`listEntries`) |
| `com.standard.document` | Alternate document collection for discovery and listing |
| `site.standard.entry` | Legacy entry collection; discovery and listing (backward compatibility) |
| `com.standard.entry` | Alternate legacy entry collection for listing |
| `app.bsky.graph.follow` | Follow subjects read from the **viewer's** repo (canonical input to discovery) |
| `com.thesocialwire.folder` | User-defined folders (`PDSClient.listFolders`, mutations) |
| `com.thesocialwire.publicationPrefs` | Per-publication folder assignment, sort, and `hidden` flag on the user's PDS |

JSON lexicons for Social Wire–specific records live under **`packages/lexicons/`** (`com.thesocialwire.*`).

### Sidebar folders & pseudo-folders

Real folders are `com.thesocialwire.folder` records with AT-URIs. The sidebar also uses **pseudo-folder** sentinels (not stored on the PDS). `__my__` and `__hidden__` are exported from `pdsClient.ts`; `__all__` is display-only in `AppSidebar.tsx`.

| Sentinel | Constant / usage | Behavior |
|----------|------------------|----------|
| `__all__` | Display-only on the “All Publications” row (`AppSidebar.tsx`) | Selection state is **`selectedFolderUri === null`** — unfoldered publications you follow (excluding your own, which appear under My Publications). |
| `__my__` | `PSEUDO_FOLDER_MY_URI` | **My Publications**: publications where the author DID matches the viewer (or `publicationId` matches the viewer). |
| `__hidden__` | `PSEUDO_FOLDER_HIDDEN_URI` | **Hidden Publications**: pubs with `com.thesocialwire.publicationPrefs.hidden === true`. The footer checkbox **“Show Hidden Publications folder”** controls whether this row appears (`useShowHiddenFolder`). |

### Client-only persistence

These **localStorage** keys are browser-only convenience (no secrets):

| Key | Purpose |
|-----|---------|
| `the-social-wire.react-query.v1` | Dehydrated TanStack Query cache (`PersistQueryClientProvider` in `providers.tsx`) |
| `the-social-wire.show-hidden-folder` | Whether the Hidden Publications pseudo-folder is shown (`useShowHiddenFolder`) |
| `the-social-wire.read-state.v1` | Read/unread map for entry AT-URIs (`entryReadStateStorage.ts`; updates suppressed while viewing the hidden folder per `ReadRouteContext`) |

**React Query persistence scope:** only queries that pass `shouldDehydrateQuery` are written: `["discovery", did]`, and **`["entries", authorDid]`** only when the infinite list is small (≤ 3 pages and ≤ 120 entries). Other query keys are not persisted. Persist writes are throttled (2s); max age 7 days.

### Discovery & entry lists (streaming & cache)

- **Discovery:** `discoverPublications` accepts **`onProgress`**, invoked with the **full ordered list so far** each time a followed account resolves to a publication. `useDiscovery` / `useRefreshDiscovery` forward that to **`queryClient.setQueryData(DISCOVERY_QUERY_KEY(did), …)`**, so the sidebar updates incrementally while probes run. Initial call passes `[]`.
- **Entries:** `listEntries` accepts **`onProgress`** when a non-empty page is ready (with the encoded infinite-query cursor). `useEntries` uses this **only for the first infinite page** to patch the first page into cache early on slow PDS responses.

### Key Libraries

| Library | Purpose |
|---------|---------|
| `@atproto/oauth-client-browser` | ATProto OAuth PKCE + DPoP |
| `@atproto/api` | XRPC Agent for PDS record operations |
| `@tanstack/react-query` | Server state, infinite queries, mutations |
| `@tanstack/react-virtual` | Virtualised entry list |
| `dompurify` | Client-side HTML sanitisation (defence in depth) |
| shadcn/ui | UI components (base-nova style, `@base-ui/react`) |

## Directory Structure

```
src/
  app/
    layout.tsx          # Root shell (Providers, EnvironmentBanner)
    providers.tsx       # PersistQueryClientProvider + AuthProvider
    page.tsx            # Redirects to /read
    (auth)/
      login/page.tsx    # Handle input + signIn redirect
      callback/page.tsx # OAuth callback handler
    read/
      layout.tsx        # Auth guard + three-pane shell (SidebarProvider)
      page.tsx          # Empty state
      [pubId]/page.tsx  # Entry list + entry detail
  components/
    AppSidebar/         # Sidebar with folders + publications
    EntryList/          # Virtualised entry list
    EntryDetail/        # Sanitised HTML renderer
    shared/             # Avatar, EnvironmentBanner
  hooks/
    useAuth.tsx         # Auth context
    usePDSClient.ts     # Memoised PDSClient from OAuthSession
    useFolders.ts       # Folder CRUD
    usePublications.ts  # Discovery + publication prefs
    useEntries.ts       # Entry list + entry detail
  lib/
    auth.ts             # OAuth client
    pdsClient.ts        # PDS XRPC helpers
    atprotoClient.ts    # Public ATProto discovery + content reads
    sanitize.ts         # DOMPurify wrapper
```

## Testing

```bash
# Run all tests
bun run test

# With coverage
bun run test:coverage
```

Tests live in `src/__tests__/`. The suite uses:
- **bun:test** — test runner
- **@testing-library/react** — component/hook tests
- **MSW** — mock public ATProto XRPC (`src/__tests__/mocks/`)
- **jsdom** — DOM environment (configured in `bunfig.toml`)

## Type Check

```bash
bun run typecheck
```

## Deployment

The web app deploys to Vercel. Set `NEXT_PUBLIC_APP_ENV=prod` in production.

Environment banners:
- **`local`** — blue banner ("Running locally")
- **`dev`** — amber banner ("You're on the dev server")
- **`prod`** — no banner
