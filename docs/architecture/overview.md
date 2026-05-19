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
   com.thesocialwire.*                     ├── Discovery (follows)
   app.bsky.graph.follow                   ├── Profiles
          │                                └── Author repo reads (default)
          │
          ▼ (optional, feature-flagged)
   Social Wire gateway (Fly, ams)
     /v1/sync/preferences, /v1/pds/cache/record
     /v1/appview/*  ← Thin AppView (Level-1 index + read_marks)
          │
          ▼
     Supabase Postgres (content_items, read_marks, pds_repo_record_cache)
```

## Data Ownership

The Social Wire follows a protocol-first ownership model:

| Data | Where | Who owns it |
|------|-------|-------------|
| Follow graph | `app.bsky.graph.follow` on user's PDS | User |
| Folders | `com.thesocialwire.folder` on user's PDS | User |
| Publication folder assignment | `com.thesocialwire.publicationPrefs` on user's PDS | User |
| Entry list rows (default) | Author PDS `listRecords` on `site.standard.*` / `com.standard.*` | Authors |
| Entry list rows (optional) | Gateway Thin AppView `content_items` index | Derived (Level-1 only) |
| Entry detail / bodies | Author PDS `getRecord` | Authors |
| Read state (canonical) | `com.thesocialwire.entryReadState` on viewer PDS | User |
| Read marks in index (optional) | Gateway `read_marks` — write-through + firehose mirror | Derived |

User organisation data and canonical read writes remain on the PDS. When the Thin AppView is disabled or unavailable, clients fall back to direct author-PDS entry listing. See [appview.md](appview.md).

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

When `ENABLE_THIN_APPVIEW` is enabled on the gateway, a separate Fly **worker** process ingests Jetstream commits into `content_items` and mirrors `com.thesocialwire.entryReadState` into `read_marks`. Clients may route **entry list** queries to `GET /v1/appview/entries` while keeping **entry detail** and **read writes** on the PDS.

Enrollment (`POST /v1/appview/enroll`) backfills followed author DIDs after client-side discovery because the global relay may miss very new repos.

Full design: [appview.md](appview.md). Deployment: [services/api/README.md](../../services/api/README.md).

## Deployment

### Infrastructure

```
GitHub (source)
       │
       ▼ push to main / dev
GitHub Actions
       │
       ├─ build-web: bun install → turbo build → Vercel
       └─ deploy-api: flyctl deploy (Fly.io, remote build)
```

### Environments

| Environment | Branch | API hosting |
|-------------|--------|-------------|
| Production | `main` | Fly app from `FLY_APP_PROD` + optional worker app |
| Development | `dev` | Fly app from `FLY_APP_DEV` + optional worker app |
| Local | — | `swift run` / `infra/docker` compose (builds `services/api`) |

### Local Stack

```
Caddy :443 (TLS)
  ├── api.{DOMAIN}       → API :8080
  └── portainer.{DOMAIN} → Portainer :9000

Portainer :9000 (HTTP), :9443 (HTTPS)
  └── manages Docker containers

API :8080
  └── Hummingbird 2 service
```
