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
User's PDS (ATProto)
  └─ com.thesocialwire.folder          ← useFolders / useCreateFolder
  └─ com.thesocialwire.publicationPrefs ← usePublicationPrefs / useSetPublicationFolder

Public ATProto XRPC
  └─ app.bsky.graph.getFollows         ← useDiscovery / useRefreshDiscovery
  └─ com.atproto.repo.listRecords      ← useDiscovery / useEntries
  └─ com.atproto.repo.getRecord        ← useEntry
```

All user organisation data (folders, publication folder assignments) is stored on the user's own PDS — not in the Social Wire backend.

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
    providers.tsx       # QueryClientProvider + AuthProvider
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
