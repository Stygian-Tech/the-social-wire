# Architecture Overview

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         Clients                                  │
│                                                                  │
│  Web (Next.js 16.2+, Railway)   iOS/iPadOS (SwiftUI, App Store) │
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
   Social Wire Gateway (Railway)
     /xrpc/app.thesocialwire.* (eligible JSON queries/procedures)
     /v1/* compatibility, streams, cached reads, L@tr, telemetry
          │
          ▼
     Railway Redis (projection/PDS caches, PLC/RSS leases, ranking primitives)
     Railway Postgres (content_items, read state, ingest/repair/Operations state)
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
| Hosted caches and leases | Private Railway Redis | Disposable and rebuildable |

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

With `ENABLE_THIN_APPVIEW` enabled on AppView, **Charybdis** (the
`appview-worker` process) ingests standard.site commits from Jetstream or the
environment-matched Tap service, polls subscribed Skyreader RSS feeds, and
writes derived `content_items`. Clients load the sidebar and first feed page via
**`GET /v1/appview/bootstrap-stream`**, then use Lexicon-defined
`app.thesocialwire.publication.*` and `app.thesocialwire.appview.*` XRPC methods
for eligible JSON reads and mutations. Compatibility `/v1/*` routes remain
documented in OpenAPI. Web performs only narrow author-PDS URL/embed enrichment
when indexed standard.site detail lacks a usable destination. The separate
Operations service records environment-scoped health, gaps, recovery jobs, and
audited operator actions through its own XRPC namespace and compatibility
routes.

Enrollment (`app.thesocialwire.appview.enrollSources`, with a
`app.thesocialwire.appview.enrollSources` procedure) backfills followed author DIDs
after client-side discovery because the global relay may miss very new repos.

Full designs: [appview.md](appview.md) and [redis.md](redis.md). Railway deploys each service from its config in [`railway/`](../../railway/README.md).

## Deployment

### Infrastructure

Development and production run as isolated Railway environments. Web,
Operations Web, Gateway, AppView, Charybdis, Operations, Tap, and Railway
Postgres deploy in each environment. A private disposable Redis is currently
selected by Gateway, AppView, and Charybdis in both environments; Postgres cache
tables remain available as rollback backends. Service-to-service traffic uses
Railway private networking.

```
GitHub (source)
       │
       ▼ push to main or dev
GitHub Actions
       │
       ├─ web / operations-web
       ├─ gateway / appview / charybdis / operations / tap
       └─ lexicons / spec → CI — Required
```

Railway's GitHub integration deploys the environment that tracks each branch after source
changes. GitHub Actions validates the repository but does not deploy infrastructure.
Gateway's Railway pre-deploy command applies pending database migrations before startup.

### Environments

| Environment | Branch | Backend hosting |
|-------------|--------|-----------------|
| Production | `main` | Railway Web, Operations Web, Gateway, AppView, Charybdis, Operations, Tap, and Postgres |
| Development | `dev` | Railway Web, Operations Web, Gateway, AppView, Charybdis, Operations, Tap, and Postgres |
| Local | — | Web runs in local mode; Swift service integration uses `APP_ENV=dev` plus an isolated disposable Postgres URL |

### Local development

Run Swift services directly as described in the root README, with Gateway,
AppView, and Charybdis pointed at the same isolated disposable Postgres database.
SQLite backends remain implemented, but all three process entry points currently
share the Operations `APP_ENV=dev|prod` guard, so `APP_ENV=local` startup is not
runnable.

## Verification

See [Test plans](../test-plans/README.md) for commands and coverage inventory per package.
