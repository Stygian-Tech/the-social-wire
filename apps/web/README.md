# The Social Wire — Web

Next.js 16.2+ web client for The Social Wire, built with Bun.

## Prerequisites

- [Bun](https://bun.sh) — use the version pinned in the monorepo root [`package.json`](../../package.json) (`packageManager`)
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
| `NEXT_PUBLIC_ATPROTO_CLIENT_ID` | Optional override for a nonstandard hosted OAuth client ID. Railway Development and Production default to same-origin `/oauth-client-metadata.json` |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_ORIGIN` | Optional: `http://127.0.0.1:PORT` — SSR / first-paint port fallback for loopback redirects |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_CALLBACK_PATH` | Optional loopback redirect path (default `/callback`) |
| `NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE` | Optional: `true` / `false` — override whether parameterized loopback OAuth is used in dev |
| `NEXT_PUBLIC_USE_THIN_APPVIEW` | AppView read path switch. It is enabled unless explicitly set to `false`; current entry lists and detail require AppView routes |
| `NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED` | Enables the Wire News Edition UI only after Corpus Edge contract v2 is available. Local dummy-data previews enable it automatically |
| `NEXT_PUBLIC_SOCIALWIRE_API_URL` | Social Wire gateway base URL for authenticated sidebar, AppView, and sync routes (default `https://api.thesocialwire.app`) |
| `NEXT_PUBLIC_SITE_URL` | Canonical public Web origin for metadata and absolute URLs; set to the environment's Railway custom domain |

## Architecture

### Auth

Authentication uses ATProto OAuth (PKCE + DPoP) via `@atproto/oauth-client-browser`.

- `src/lib/auth.ts` — OAuth client setup, signIn redirect, callback handling, session restore
- `src/hooks/useAuth.tsx` — `AuthProvider` context; exposes `session.did`, `getAuthFetch()`, `getOAuthSession()`
- `src/lib/pdsClient.ts` — XRPC helpers for reading/writing ATProto records on the user's PDS (`new Agent(oauthSession)`)
- `src/lib/atprotoClient.ts` — public ATProto XRPC helpers for discovery and standard.site entry reads
- `src/lib/socialWireXrpc.ts` — Lexicon NSIDs and authenticated XRPC transport helper
- `src/lib/thinAppViewClient.ts` — gateway XRPC client for AppView feeds/detail, read marks, enrollment, purge, unread counts, and mark-all-read
- `src/lib/publicationProjectionClient.ts` — XRPC sidebar projection client
- `src/lib/bootstrapStreamClient.ts` — NDJSON bootstrap stream consumer
- `src/lib/feedRefresh.ts` — proactive first-page feed merge helpers

The web client uses Lexicon-defined Social Wire XRPC methods for eligible JSON
queries and procedures. The Gateway retains documented `/v1/*` compatibility
adapters, while bootstrap streaming and telemetry remain HTTP transports.

#### Local ATProto OAuth (`next dev`)

Local dev does **not** use the static prod `public/client-metadata.json` at runtime (`/oauth-client-metadata.json` is served dynamically per host). On your machine the browser uses a **parameterized loopback** client ID (`http://localhost?redirect_uri=…&scope=…` per `@atproto/oauth-types`, RFC 8252).

- **When loopback applies:** app env is `local`, or **`dev` during `next dev`**, or **`next dev` with app env unset**. Hosted Railway Development and Production use the Web service's same-origin `/oauth-client-metadata.json` unless `NEXT_PUBLIC_ATPROTO_CLIENT_ID` intentionally overrides it.
- **Redirect URIs:** `http://127.0.0.1:<devPort>/callback` and `http://[::1]:<devPort>/callback`, derived from `window.location.port` when you sign in. The client may redirect **`localhost` → `127.0.0.1`** after load so IndexedDB matches the redirect origin.
- **Overrides:** `NEXT_PUBLIC_ATPROTO_LOOPBACK_ORIGIN` (port fallback when `window` is missing), `NEXT_PUBLIC_ATPROTO_LOOPBACK_CALLBACK_PATH` (default `/callback`), `NEXT_PUBLIC_ATPROTO_LOOPBACK_FORCE=false` to force hosted client ID in dev.
- **Callback route:** Never run idle `oauthClient.init()` concurrently on **`/callback`**, or a race can strip `#code=` / `#state=` when the OAuth client redirects `localhost → 127.0.0.1`. `AuthProvider` skips restore on that path until `handleCallback()` finishes.

Sign in with a **real** handle; tokens are issued by your PDS. There is **no OAuth bypass** — that would not produce valid `com.atproto.repo.*` writes to a real PDS.

### Data Flow

```
User's PDS (OAuth session — canonical for repo + graph on the viewer's repo)
  └─ app.thesocialwire.folder           ← useFolders / useCreateFolder
  └─ app.thesocialwire.publicationPrefs ← usePublicationPrefs / useSetPublicationFolder
  └─ app.bsky.graph.follow              ← AppView server-side sidebar discovery

Author repos (PLC-resolved PDS; com.atproto.repo.* — not the App View relay)
  └─ site.standard.publication  ← publication records
  └─ site.standard.document     ← current entry records
  └─ site.standard.entry        ← backward-compatible entry records
  └─ com.standard.*             ← compatibility probes only; not registered Social Wire lexicons

Public App View (https://public.api.bsky.app — no OAuth on these calls)
  └─ com.atproto.identity.resolveHandle
  └─ app.bsky.actor.getProfile         ← viewer/profile enrichment

Social Wire gateway (default read path)
  └─ GET /v1/appview/bootstrap-stream   ← initial sidebar + unread + first feed page (NDJSON)
  └─ /xrpc/app.thesocialwire.publication.* ← sidebar projection/refresh/resolve
  └─ /xrpc/app.thesocialwire.appview.*     ← feeds, detail, unread state, enrollment
```

All user organisation data (folders, publication prefs, subscriptions) is stored on the user's own PDS; web mutations write those records directly with the OAuth session. Feed read/unread state is local-first and synchronized to Social Wire AppView. Initial load stays on the HTTP NDJSON bootstrap stream; eligible JSON reads and mutations use Lexicon-defined Social Wire XRPC methods. Compatibility `/v1/*` aliases remain documented in OpenAPI. For standard.site rows that lack an original/embed URL, the detail hook may read the author record only to recover that URL. See [docs/architecture/appview.md](../../docs/architecture/appview.md).

#### PDS-first reads vs public App View

OAuth access tokens are **audience-bound to the user's PDS**, not to the Bluesky App View. The web app uses a session-backed `@atproto/api` `Agent` for viewer-repo `com.atproto.repo.*` reads and writes. Targeted URL enrichment resolves an author's own PDS and tries public `com.atproto.repo.*` reads there; it only retries with the OAuth fetch handler after an authorization-shaped failure. Identity/profile helpers use `https://public.api.bsky.app` without the viewer's PDS-bound OAuth token.

### Lexicons & collections

Lexicon **collection** (NSID) strings used in the web client match `apps/web/src/lib/atprotoClient.ts` and `apps/web/src/lib/pdsClient.ts`:

| Collection | Role in the web app |
|------------|---------------------|
| `site.standard.publication` | Publication identity used by subscriptions and targeted row hydration |
| `com.standard.publication` | Unregistered compatibility probe for targeted record reads |
| `site.standard.document` | Primary document collection for targeted URL recovery |
| `com.standard.document` | Unregistered compatibility probe for legacy direct reads |
| `site.standard.entry` | Legacy entry collection retained for backward-compatible direct reads |
| `com.standard.entry` | Unregistered compatibility probe for legacy direct reads |
| `app.bsky.graph.follow` | Server-side AppView discovery input; not crawled by the web client |
| `app.thesocialwire.folder` | User-defined folders (`PDSClient.listFolders`, mutations) |
| `app.thesocialwire.publicationPrefs` | Per-publication folder assignment and sort on the user's PDS (legacy `hidden` may still decode from old records but the client clears it on write) |

Feed read/unread state is local-first for immediate UI and synchronized to
Social Wire AppView for unread filtering and counts. The current web and Apple
clients do not create `app.thesocialwire.entryReadState` records on the viewer's
PDS.

JSON lexicons for Social Wire–specific records live under **`packages/lexicons/`** (`app.thesocialwire.*`).

### Sidebar folders & pseudo-folders

Real folders are `app.thesocialwire.folder` records with AT-URIs. The sidebar also uses a **pseudo-folder** sentinel for **My Publications** (not stored on the PDS). `__my__` is exported from `pdsClient.ts`; `__all__` is display-only in `AppSidebar.tsx`.

| Sentinel | Constant / usage | Behavior |
|----------|------------------|----------|
| `__all__` | Display-only on the “All Publications” row (`AppSidebar.tsx`) | Selection state is **`selectedFolderUri === null`** — unfoldered publications you follow (excluding your own, which appear under My Publications). |
| `__my__` | `PSEUDO_FOLDER_MY_URI` | **My Publications**: publications where the author DID matches the viewer (or `publicationId` matches the viewer). |

### Client-only persistence

These browser-side keys are convenience caches (no secrets):

| Key | Storage | Purpose |
|-----|---------|---------|
| `the-social-wire.react-query.v2` | IndexedDB | Dehydrated TanStack Query cache (`PersistQueryClientProvider` in `providers.tsx`) |
| `the-social-wire.read-state.v1` | localStorage | Local read/unread map for entry AT-URIs (`entryReadStateStorage.ts`) |
| `the-social-wire.sidebar-expanded-keys.v1` | localStorage | Folder/section expansion state, scoped by viewer DID |

**React Query persistence scope:** only queries that pass `shouldDehydrateQuery` are written: sidebar projection and viewer-scoped `entries` / `aggregateEntries` queries when the infinite list is small (at most 3 pages and 150 entries). Other query keys are not persisted. Writes are throttled (2s); max age is 7 days.

### Discovery, sidebar & entry lists

- **Initial load:** `PublicationSidebarProvider` consumes **`GET /v1/appview/bootstrap-stream`** for progressive sidebar, unread counts, first-unread selection, and the first feed page. `usePublicationSidebarData` is the compatibility facade over that provider.
- **Entries:** `useEntries` and aggregate feeds call AppView. `useProactiveFeedRefresh` polls and refocus-refreshes the active publication's first page via `feedRefresh.ts`; `useEntry` loads the flat AppView detail response.
- **Discovery and resolution:** AppView owns follow-graph discovery and add-publication resolution; the web client does not crawl followed repositories or merge a client-side fallback.

### Read Later and Archive

`/saved` and `/archive` are sibling reader destinations that reuse the three-pane shell and article embed. `/saved/settings` redirects to `/saved`; there is no provider selector. All reads, mutations, and lazy migration use the same-origin `link.latr.bookmarks.*` XRPC proxy with no direct-PDS fallback.

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
      layout.tsx          # Auth guard + three-pane reader shell
      page.tsx            # Empty state
      [...pubId]/page.tsx # Entry list + entry detail
    saved/                 # Active L@tr saves + settings redirect
    archive/               # Archived L@tr saves
    me/publications/       # Signed-in viewer publications
  components/
    AppSidebar/         # Sidebar with folders + publications
    EntryList/          # Virtualised entry list
    EntryDetail/        # Sanitised HTML renderer
    SavedLinks/         # Read Later / Archive list and detail UI
    shared/             # Avatar, EnvironmentBanner
  hooks/
    useAuth.tsx         # Auth context
    usePDSClient.ts     # Memoised PDSClient from OAuthSession
    useFolders.ts       # Folder CRUD
    usePublications.ts  # Discovery + publication prefs (legacy path)
    usePublicationSidebarData.ts  # Facade over sidebar provider + bootstrap state
    useEntries.ts       # AppView entry lists, aggregate feeds, and detail
    useProactiveFeedRefresh.ts  # Background feed first-page refresh
  lib/
    auth.ts             # OAuth client
    pdsClient.ts        # Direct viewer-PDS XRPC helpers + L@tr list assembly
    atprotoClient.ts    # Public ATProto discovery + content reads
    thinAppViewClient.ts # Gateway Thin AppView client
    publicationProjectionClient.ts # Sidebar projection client
    socialWireXrpc.ts   # Social Wire NSIDs + authenticated XRPC transport
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

Development and Production are separate Railway services built from `apps/web`:

| Environment | Web origin | `NEXT_PUBLIC_APP_ENV` | `NEXT_PUBLIC_SOCIALWIRE_API_URL` |
|-------------|------------|-----------------------|----------------------------------|
| Development | `https://testing.thesocialwire.app` | `dev` | `https://api.testing.thesocialwire.app` |
| Production | `https://thesocialwire.app` | `prod` | `https://api.thesocialwire.app` |

Set `NEXT_PUBLIC_SITE_URL` to the Web origin in the same row. The public domains are Railway custom domains and are the stable OAuth/CORS identities; do not publish generated `*.up.railway.app` URLs as OAuth client IDs. Each Web service serves same-origin metadata: Development redirects to `https://testing.thesocialwire.app/callback`, and Production redirects to `https://thesocialwire.app/callback`. The matching Gateway's `OAUTH_PUBLIC_ORIGIN` and CORS configuration must use that Web origin. Server-only L@tr credentials belong on the matching Railway Web service.

Environment banners:
- **`local`** — blue banner ("Running locally")
- **`dev`** — amber banner ("You're on the dev server")
- **`prod`** — no banner
