# The Social Wire — Web

Next.js 16.2+ web client for The Social Wire, built with Bun.

## Prerequisites

- [Bun](https://bun.sh) — use the version pinned in the monorepo root [`package.json`](../package.json) (`packageManager`)
- Node.js ≥ 22 (for shadcn/ui compatibility)
- An ATProto account (Bluesky or any PDS)

## Quick Start

```bash
# From the monorepo root
bun install

# Start the dev server
cd apps/web
cp .env.example .env.local   # optional; uncomment vars as needed
bun run dev
```

The app runs at [http://localhost:3000](http://localhost:3000).

## Environment Variables

Copy `.env.example` to `.env.local` or create `.env.local` manually (see **Environment Variables**). No secrets are required for local ATProto OAuth loopback.

| Variable | Description |
|----------|-------------|
| `NEXT_PUBLIC_APP_ENV` | `prod` / `dev` / `local` — banner + OAuth mode (see **Local ATProto OAuth** below). Server also reads `APP_ENV`; `next.config` forwards it to the client bundle when `NEXT_PUBLIC_*` is unset |
| `NEXT_PUBLIC_ATPROTO_CLIENT_ID` | Optional override for hosted OAuth client ID. Default: same-origin `/client-metadata.json` (dynamic `redirect_uris` for preview/dev hosts) |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_ORIGIN` | Optional: `http://127.0.0.1:PORT` — SSR / first-paint port fallback for loopback redirects |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_CALLBACK_PATH` | Optional loopback redirect path (default `/callback`) |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE` | Optional: `true` / `false` — override whether parameterized loopback OAuth is used in dev |
| `NEXT_PUBLIC_USE_THIN_APPVIEW` | When `true`, entry **lists** load from gateway `GET /v1/appview/entries` instead of author PDS `listRecords` (entry detail stays PDS-direct) |
| `NEXT_PUBLIC_SOCIALWIRE_API_URL` | Gateway base URL for Thin AppView and future authenticated routes (default `https://api.thesocialwire.app`) |

## Architecture

### Auth

Authentication uses ATProto OAuth (PKCE + DPoP) via `@atproto/oauth-client-browser`.

- `src/lib/auth.ts` — OAuth client setup, signIn redirect, callback handling, session restore
- `src/hooks/useAuth.tsx` — `AuthProvider` context; exposes `session.did`, `getAuthFetch()`, `getOAuthSession()`
- `src/lib/pdsClient.ts` — XRPC helpers for reading/writing ATProto records on the user's PDS (`new Agent(oauthSession)`)
- `src/lib/atprotoClient.ts` — public ATProto XRPC helpers for discovery and standard.site entry reads
- `src/lib/thinAppViewClient.ts` — optional gateway client for Thin AppView entry lists, read-mark write-through, enrollment, purge, unread counts, mark-all-read
- `src/lib/publicationProjectionClient.ts` — sidebar projection client (`/v1/publications/*`)
- `src/lib/bootstrapStreamClient.ts` — NDJSON bootstrap stream consumer
- `src/lib/feedRefresh.ts` — proactive first-page feed merge helpers

#### Local ATProto OAuth (`next dev`)

Local dev does **not** use the static prod `public/client-metadata.json` at runtime (`/client-metadata.json` is served dynamically per host). On your machine the browser uses a **parameterized loopback** client ID (`http://localhost?redirect_uri=…&scope=…` per `@atproto/oauth-types`, RFC 8252).

- **When loopback applies:** app env is `local`, or **`dev` during `next dev`**, or **`next dev` with app env unset**. Hosted preview/production use same-origin `/client-metadata.json` unless `NEXT_PUBLIC_ATPROTO_CLIENT_ID` overrides.
- **Redirect URIs:** `http://127.0.0.1:<devPort>/callback` and `http://[::1]:<devPort>/callback`, derived from `window.location.port` when you sign in. The client may redirect **`localhost` → `127.0.0.1`** after load so IndexedDB matches the redirect origin.
- **Overrides:** `NEXT_PUBLIC_ATPROTO_LOOPBACK_ORIGIN` (port fallback when `window` is missing), `NEXT_PUBLIC_ATPROTO_LOOPBACK_CALLBACK_PATH` (default `/callback`), `NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE=false` to force hosted client ID in dev.
- **Callback route:** Never run idle `oauthClient.init()` concurrently on **`/callback`**, or a race can strip `#code=` / `#state=` when the OAuth client redirects `localhost → 127.0.0.1`. `AuthProvider` skips restore on that path until `handleCallback()` finishes.

Sign in with a **real** handle; tokens are issued by your PDS. There is **no OAuth bypass** — that would not produce valid `com.atproto.repo.*` writes to a real PDS.

### Data Flow

```
User's PDS (OAuth session — canonical for repo + graph on the viewer's repo)
  └─ app.thesocialwire.folder           ← useFolders / useCreateFolder
  └─ app.thesocialwire.publicationPrefs ← usePublicationPrefs / useSetPublicationFolder
  └─ app.bsky.graph.follow              ← discoverPublications (canonical follow subjects)

Author repos (PLC-resolved PDS; com.atproto.repo.* — not the App View relay)
  └─ site.standard.publication, com.standard.publication  ← discovery probes (first)
  └─ site.standard.document, com.standard.document       ← discovery + entry listing
  └─ site.standard.entry, com.standard.entry             ← discovery + entry listing (legacy entry NSIDs)

Public App View (https://public.api.bsky.app — no OAuth on these calls)
  └─ com.atproto.identity.resolveHandle
  └─ app.bsky.graph.getFollows         ← merged with PDS graph when under cap
  └─ app.bsky.actor.getProfile         ← follow enrichment (useViewerProfile also uses repo profile fallback)

Social Wire gateway (optional — NEXT_PUBLIC_USE_THIN_APPVIEW=true)
  └─ GET /v1/appview/bootstrap-stream   ← initial sidebar + unread + first feed page (NDJSON)
  └─ GET /v1/publications/sidebar       ← sidebar projection (refresh / phased load)
  └─ GET /v1/appview/entries            ← entry list rows (Level-1 index)
  └─ GET /v1/appview/unread-counts      ← sidebar unread badges
  └─ POST/DELETE /v1/appview/read-marks ← write-through after PDS read state
  └─ POST /v1/appview/enroll            ← backfill after sidebar load
  └─ POST /v1/appview/mark-all-read     ← scoped bulk read
```

All user organisation data (folders, publication prefs, canonical read state) is stored on the user's own PDS. Entry **detail** always reads authors' PDS records. When Thin AppView is enabled, **initial load** uses bootstrap-stream; entry **lists** come from the gateway index with proactive first-page refresh while reading. See [docs/architecture/appview.md](../../docs/architecture/appview.md).

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
| `app.thesocialwire.folder` | User-defined folders (`PDSClient.listFolders`, mutations) |
| `app.thesocialwire.publicationPrefs` | Per-publication folder assignment and sort on the user's PDS (legacy `hidden` may still decode from old records but the client clears it on write) |
| `app.thesocialwire.entryReadState` | Per-entry read timestamps on the viewer PDS (canonical); mirrored to gateway index when Thin AppView is enabled |

JSON lexicons for Social Wire–specific records live under **`packages/lexicons/`** (`app.thesocialwire.*`).

### Sidebar folders & pseudo-folders

Real folders are `app.thesocialwire.folder` records with AT-URIs. The sidebar also uses a **pseudo-folder** sentinel for **My Publications** (not stored on the PDS). `__my__` is exported from `pdsClient.ts`; `__all__` is display-only in `AppSidebar.tsx`.

| Sentinel | Constant / usage | Behavior |
|----------|------------------|----------|
| `__all__` | Display-only on the “All Publications” row (`AppSidebar.tsx`) | Selection state is **`selectedFolderUri === null`** — unfoldered publications you follow (excluding your own, which appear under My Publications). |
| `__my__` | `PSEUDO_FOLDER_MY_URI` | **My Publications**: publications where the author DID matches the viewer (or `publicationId` matches the viewer). |

### Client-only persistence

These **localStorage** keys are browser-only convenience (no secrets):

| Key | Purpose |
|-----|---------|
| `the-social-wire.react-query.v1` | Dehydrated TanStack Query cache (`PersistQueryClientProvider` in `providers.tsx`) |
| `the-social-wire.read-state.v1` | Read/unread map for entry AT-URIs (`entryReadStateStorage.ts`) |

**React Query persistence scope:** only queries that pass `shouldDehydrateQuery` are written: `["discovery", did]`, and **`["entries", authorDid]`** only when the infinite list is small (≤ 3 pages and ≤ 120 entries). Other query keys are not persisted. Persist writes are throttled (2s); max age 7 days.

### Discovery, sidebar & entry lists

- **Thin AppView path (default when flag on):** `usePublicationSidebarData` consumes **`GET /v1/appview/bootstrap-stream`** for progressive sidebar, unread counts, first-unread selection, and first feed page. Sidebar folder/section expand state persists in **`the-social-wire.sidebar-expanded-keys.v1`** per viewer DID.
- **Legacy client discovery:** `discoverPublications` with **`onProgress`** streaming still exists for PDS-direct mode; `useDiscovery` updates React Query incrementally while probes run.
- **Entries:** When **`NEXT_PUBLIC_USE_THIN_APPVIEW=true`**, `useEntries` calls **`listEntriesFromAppView`**. **`useProactiveFeedRefresh`** polls and refocus-refreshes the active publication's first page via **`feedRefresh.ts`**. **`getEntry`** / entry detail remain PDS-direct in all modes.

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
    usePublications.ts  # Discovery + publication prefs (legacy path)
    usePublicationSidebarData.ts  # Bootstrap stream + sidebar projection
    useEntries.ts       # Entry list + entry detail (optional Thin AppView)
    useProactiveFeedRefresh.ts  # Background feed first-page refresh
  lib/
    auth.ts             # OAuth client
    pdsClient.ts        # PDS XRPC helpers (+ read-mark write-through when flag on)
    atprotoClient.ts    # Public ATProto discovery + content reads
    thinAppViewClient.ts # Gateway Thin AppView client
    publicationProjectionClient.ts # Sidebar projection client
    bootstrapStreamClient.ts # NDJSON bootstrap stream
    feedRefresh.ts      # Proactive first-page feed merge
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
