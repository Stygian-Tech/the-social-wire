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
          ▼ (authenticated read path)
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
| standard.site source records | Author PDS `site.standard.document` / `site.standard.entry` | Authors |
| Entry lists and indexed detail | Gateway Thin AppView `content_items` | Derived; TTL-bound |
| RSS entry bodies | Parsed feed content in `content_items.render_json` when supplied | Derived; TTL-bound |
| Read state | Client local cache + Social Wire AppView `read_marks`/read floors | User-visible derived state |

User organisation data remains on the PDS. Feed read/unread state is not written to ATProto repo records. Current clients require AppView for feeds and entry detail; a disabled or unavailable AppView produces an unavailable read path rather than a long-lived PDS-direct list fallback. See [appview.md](appview.md).

## Auth Flow

```
User enters handle
       │
       ▼
Resolve DID via bsky.social / PLC directory
       │
       ▼
Discover the PDS protected-resource metadata and authorization issuer
       │
       ▼
Submit a pushed authorization request (PAR) with PKCE + DPoP
       │
       ▼
Redirect to the discovered authorization endpoint with request_uri
       │
       ▼
User approves on PDS
       │
       ▼
Callback: exchange code at the discovered token endpoint → DPoP-bound tokens
       │
       ├─── access token (memory) → PDS XRPC writes (via Agent/client)
       │
       └─── refresh token (Keychain / sessionStorage) → silent refresh
```

## Direct ATProto Reads

Public ATProto reads still support identity, follows, profiles, direct user-record writes, and narrow publisher-record enrichment. The legacy discovery path probes author PDSes as follows:

1. Fetch follows via `app.bsky.graph.getFollows`
2. Probe each followed DID with `com.atproto.repo.listRecords?collection=site.standard.entry`
3. Read `site.standard.*` records with `com.atproto.repo.listRecords` / `getRecord` when direct enrichment is needed

See [discovery.md](discovery.md) for the detailed walkthrough.

## Thin AppView

With `ENABLE_THIN_APPVIEW` enabled on AppView, **Charybdis** (the `appview-worker` process) ingests standard.site commits from Jetstream or the environment-matched Tap service, polls subscribed Skyreader RSS feeds, and writes derived `content_items`. Clients load the sidebar and first feed page via **`GET /v1/appview/bootstrap-stream`**, paginate publication lists with `GET /v1/appview/entries` and aggregate feeds with `GET /v1/appview/feed`, and load indexed detail through `GET /v1/appview/entry`. Web performs only narrow author-PDS URL/embed enrichment when indexed standard.site detail lacks a usable destination. Feed read writes go to AppView read-mark and mark-all-read routes. The separate Operations service records environment-scoped health, gaps, recovery jobs, and audited operator actions.

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
       ├─ build-web / build-operations → Vercel projects
       ├─ test-gateway / test-appview / test-appview-worker / test-operations / test-tap-image
       ├─ deploy-gateway / deploy-appview / deploy-appview-worker → Fly.io
       ├─ deploy-operations / deploy-tap → Fly.io development; production is manual
       └─ supabase-validate / supabase-push
```

### Environments

| Environment | Branch | Backend hosting |
|-------------|--------|-----------------|
| Production | `main` | Fly Gateway, AppView, and Charybdis auto-deploy on matching path changes; Operations and Tap require manual rollout (all `iah`) |
| Development | `dev` | Fly Gateway, AppView, Charybdis, Operations, and Tap auto-deploy on matching path changes (all `iah`) |
| Local | — | Gateway/AppView/Charybdis use `APP_ENV=local` + SQLite; Operations uses `APP_ENV=dev` + a development Postgres URL |

### Local development

Run Swift services directly (see root README) with AppView and Charybdis pointed at the same explicit SQLite file. Under `APP_ENV=local`, services use SQLite; `supabase start` is for applying and validating Postgres migrations, not a runtime replacement for local service storage.

## Verification

See [Test plans](../test-plans/README.md) for commands and coverage inventory per package.
