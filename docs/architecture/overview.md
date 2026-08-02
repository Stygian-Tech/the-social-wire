# Architecture Overview

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         Clients                                  │
│                                                                  │
│   Web (Next.js 16.2+, Vercel)    iOS/iPadOS (SwiftUI, App Store)│
│          │                                    │                  │
│          └──────── ATProto OAuth (PKCE+DPoP) ─┘                 │
└────────────────────────────┬────────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
   User's ATProto PDS               Public ATProto XRPC
   (user-controlled)                (Bluesky App View + author PDS)
          │                                │
   app.thesocialwire.*                     ├── Discovery (follows)
   app.bsky.graph.follow                   ├── Profiles
          │                                └── Author repo reads (default)
          │
          ▼ (optional, feature-flagged)
   Social Wire gateway (Fly, iah)
     /v1/sync/preferences, /v1/pds/cache/record
     /v1/publications/* (write-through + proxied sidebar)
     /v1/appview/*  ← Thin AppView (proxied to services/appview)
          │
          ▼
     Supabase Postgres (AWS us-east-1; content_items, read_marks, sidebar_projection_cache, pds_repo_record_cache)
```

## Data Ownership

The Social Wire follows a protocol-first ownership model:

| Data | Where | Who owns it |
|------|-------|-------------|
| Follow graph | `app.bsky.graph.follow` on user's PDS | User |
| Folders | `app.thesocialwire.folder` on user's PDS | User |
| Publication folder assignment | `app.thesocialwire.publicationPrefs` on user's PDS | User |
| Entry list rows (default) | Author PDS `listRecords` on `site.standard.*` / `com.standard.*` | Authors |
| Entry list rows (optional) | Gateway Thin AppView `content_items` index | Derived (Level-1 only) |
| Entry detail / bodies | Author PDS `getRecord` | Authors |
| Read state | Client local cache + Social Wire AppView `read_marks`/read floors | User-visible derived state |

User organisation data remains on the PDS. Feed read/unread state is not written to ATProto repo records. When the Thin AppView is disabled or unavailable, clients fall back to direct author-PDS entry listing. See [appview.md](appview.md).

## Auth Flow

```
User enters handle
       │
       ▼
Resolve DID via bsky.social / PLC directory
       │
       ▼
Fetch PDS metadata (authorization_endpoint)
       │
       ▼
Redirect to PDS /oauth/authorize (PKCE + DPoP)
       │
       ▼
User approves on PDS
       │
       ▼
Callback: exchange code → DPoP-bound access token + refresh token
       │
       ├─── access token (memory) → PDS XRPC writes (via Agent/client)
       │
       └─── refresh token (Keychain / sessionStorage) → silent refresh
```

## Direct ATProto Reads

Clients use public ATProto XRPC to determine if followed accounts publish standard.site entries:

1. Fetch follows via `app.bsky.graph.getFollows`
2. Probe each followed DID with `com.atproto.repo.listRecords?collection=site.standard.entry`
3. Load entry lists and detail through `com.atproto.repo.listRecords` and `com.atproto.repo.getRecord`

See [discovery.md](discovery.md) for the detailed walkthrough.

## Thin AppView (optional)

When `ENABLE_THIN_APPVIEW` is enabled on AppView, **Charybdis** (the `appview-worker` process) ingests Jetstream commits into `content_items`. Clients load the sidebar and first feed page via **`GET /v1/appview/bootstrap-stream`**, then paginate entry lists with `GET /v1/appview/entries`. Entry detail stays on the author PDS; feed read writes go to AppView read-mark and mark-all-read routes.

Enrollment (`POST /v1/appview/enroll`) backfills followed author DIDs after client-side discovery because the global relay may miss very new repos.

Full design: [appview.md](appview.md). Deploy each service from repo root via `scripts/fly-deploy-*.sh`.

## Deployment

### Infrastructure

All development and production Fly compute (Gateway, AppView, Charybdis, Operations,
and Tap) runs in Houston (`iah`). Supabase/Postgres remains in AWS `us-east-1` and is
reached through the session pooler. Service-to-service Fly traffic uses private
`.internal` addresses; only browser/client ingress uses public gateway domains. Data
residency for both compute and database projections is the United States.

```
GitHub (source)
       │
       ▼ push to main / dev
GitHub Actions
       │
       ├─ build-web: bun install → turbo build → Vercel
       ├─ deploy-gateway / deploy-appview / deploy-appview-worker → Fly.io (remote build)
       └─ supabase-validate / supabase-push
```

### Environments

| Environment | Branch | Backend hosting |
|-------------|--------|-----------------|
| Production | `main` | Fly Gateway, AppView, Charybdis, Operations, and Tap (`*-prod-*`, all in `iah`) |
| Development | `dev` | Fly Gateway, AppView, Charybdis, Operations, and Tap (`*-dev-*`, all in `iah`) |
| Local | — | `swift run Gateway` / `swift run AppView` / `swift run AppViewWorker` |

### Local development

Run Swift services directly (see root README). Optional: `supabase start` for local Postgres instead of SQLite (`APP_ENV=local`).

## Verification

See [Test plans](../test-plans/README.md) for commands and coverage inventory per package.
