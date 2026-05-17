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
   (user-controlled)                (bsky.social relay / PDS)
          │                                │
   com.thesocialwire.folder                ├── Discovery
   com.thesocialwire.publicationPrefs      ├── Content
   app.bsky.graph.follow                   └── standard.site entries
```

## Data Ownership

The Social Wire follows a protocol-first ownership model:

| Data | Where | Who owns it |
|------|-------|-------------|
| Follow graph | `app.bsky.graph.follow` on user's PDS | User |
| Folders | `com.thesocialwire.folder` on user's PDS | User |
| Publication folder assignment | `com.thesocialwire.publicationPrefs` on user's PDS | User |
| Discovered publications | Derived from follow graph + `site.standard.entry` | User/authors |
| Entry content | `site.standard.entry` records | Authors |

The Social Wire clients do not depend on a Social Wire API for user data, discovery, or content reads. If our backend disappears, users' reading preferences and readable entry records are still available through ATProto.

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
| Production | `main` | Fly app from `FLY_APP_PROD` |
| Development | `dev` | Fly app from `FLY_APP_DEV` |
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
