# The Social Wire

A reader for the [standard.site](https://standard.site) publishing ecosystem, built on ATProto.

## Overview

The Social Wire lets you read publications from people you follow on Bluesky and the broader ATProto network. Your reading preferences — folders, publication organisation — are stored on your own ATProto PDS, not on our servers.

```
Web (Next.js 16.2+)     iOS/iPadOS (SwiftUI)
       │                        │
       └─── ATProto OAuth ──────┘
                   │
       ┌───────────┴───────────┐
       ▼                       ▼
User's ATProto PDS      Social Wire gateway (Railway)
  app.thesocialwire.*     /xrpc/app.thesocialwire.* + compatibility /v1/*
  link.latr.saved.*       bootstrap stream, PDS write-through, /v1/latr/*
                               │
                               └── AppView + Charybdis
                                   Redis (disposable cache/leases)
                                   Postgres (durable derived state)
```

The current checkout adds Lexicon-defined `/xrpc/app.thesocialwire.*` aliases
and migrates eligible clients to them. As verified on 2026-08-12, those aliases
are not yet registered on the public Testing or Production gateways; deployed
clients still use the retained `/v1/*` contract until the migration ships.

## Monorepo Structure

```
the-social-wire/
  apps/
    web/             # Next.js 16.2+ reader (Bun)
    apple/           # SwiftUI iOS/iPadOS app
    operations/      # Next.js operator console (Bun)
  services/
    gateway/         # OAuth, sync, PDS writes, AppView proxy (Hummingbird; Railway)
    appview/         # Publication sidebar + Thin AppView read index (Railway)
    appview-worker/  # Charybdis: Jetstream ingestion for Thin AppView (Railway)
    jetstream-ingest/ # Durable Jetstream V2 replay + PostgreSQL inbox (Go; Railway)
    operations/      # Operations control plane (Railway)
    tap/             # Pinned Indigo Tap image (Railway)
  packages/
    lexicons/        # record schemas plus app.thesocialwire.* service XRPC lexicons
    spec/            # OpenAPI 3.1 compatibility contract + endpoint manifest
    swift/           # GatewayCore, OperationsCore, SocialWireRedis, ThinAppViewCore
  database/
    migrations/      # Provider-neutral Postgres migration history
  docs/
    architecture/
    wiki/        # Canonical public wiki Markdown (GitHub sync; manual Lichen publish)
```

## Prerequisites

| Tool | Version |
|------|---------|
| [Bun](https://bun.sh) | Matches root [`package.json`](package.json) `packageManager` (currently 1.3.x) |
| [Swift](https://swift.org/install) | 6.2+ for service/package test parity (CI uses 6.2.4) |
| [Go](https://go.dev/dl/) | 1.26.5 for the Jetstream V2 ingress service |
| [Railway CLI](https://docs.railway.com/guides/cli) | Latest (hosted operations and migration access) |
| [Xcode](https://developer.apple.com/xcode/) | 16+ (for iOS) |

## Quick Start

### Local development

```bash
# 1. Install JS dependencies
bun install

# 2. Start the web app
cd apps/web
cp .env.example .env.local
# Optional: uncomment or set vars in .env.local (defaults work for local OAuth loopback)
bun run dev
```

Open [http://localhost:3000](http://localhost:3000).

### Full-stack local dev (optional)

The service executables currently accept only `APP_ENV=dev|prod` because their
shared Operations namespace rejects `local`. Use an isolated disposable Postgres
database for local integration; never point these commands at a hosted
Development or Production database.

```bash
# Apply migrations to an isolated disposable Postgres database first.
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh

# Run each service in a separate terminal with the same disposable DATABASE_URL.
# Gateway (OAuth, sync, writes)
(cd services/gateway && APP_ENV=dev DATABASE_URL='postgresql://…' APPVIEW_BASE_URL=http://127.0.0.1:8081 GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run Gateway)

# AppView (sidebar + Thin AppView reads)
(cd services/appview && APP_ENV=dev DATABASE_URL='postgresql://…' ENABLE_THIN_APPVIEW=true GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run AppView)

# Charybdis (Jetstream ingestion)
(cd services/appview-worker && APP_ENV=dev DATABASE_URL='postgresql://…' ENABLE_THIN_APPVIEW=true TAP_CONSUMER_MODE=disabled swift run AppViewWorker)
```

### Running tests

See **[docs/test-plans/README.md](docs/test-plans/README.md)** for per-surface plans and PR checklists.

```bash
(cd apps/web && bun test)
(cd apps/operations && bun test)
(cd packages/swift/GatewayCore && swift test)
(cd packages/swift/SocialWireRedis && swift test)
(cd services/gateway && swift test)
(cd services/appview && swift test)
(cd packages/swift/ThinAppViewCore && swift test)
(cd services/appview-worker && swift test)
(cd packages/swift/OperationsCore && swift test)
(cd services/operations && swift test)
(cd services/jetstream-ingest && go test ./... && go vet ./...)

# iOS — Cmd+U in Xcode (see docs/test-plans/apple.md)
```

## Architecture Principles

- **Protocol-first where data is portable**: folders, publication preferences, subscriptions, and read-later records live on the user's own ATProto PDS
- **AppView-owned read state**: feed read/unread state is local-first in clients and synchronized to Social Wire AppView for counters and unread filtering
- **Thin AppView read path**: signed-in clients load bootstrap data, feeds, and entry detail through the gateway-backed AppView; standard.site bodies remain authoritative on publisher PDSes, while RSS feed bodies may be retained in the derived index (see [docs/architecture/appview.md](docs/architecture/appview.md))
- **Disposable acceleration**: projection/PDS caches, PLC coalescing, RSS leases, and reusable ranking sets can use Redis; PDS/Postgres remain authoritative. Development and Production currently select Redis, while Postgres cache tables remain the rollback backend (see [docs/architecture/redis.md](docs/architecture/redis.md))
- **Direct ATProto where it fits**: discovery and repo reads use public XRPC; Bluesky App View (`public.api.bsky.app`) for follows and profiles only
- **Interoperable by design**: lexicons are public — any ATProto client can read a user's Social Wire folders

## Deployment

| Component | Where |
|-----------|-------|
| Web + Operations UI | Railway |
| Gateway, AppView, Charybdis, Jetstream V2 Ingest | Railway |
| Operations + Tap | Railway |
| Durable index/state | Railway Postgres (`database/migrations/`) |
| Optional disposable cache/coordination | Private Railway Redis (currently selected in Development and Production) |
| CI/CD | GitHub Actions validates source; Railway deploys through its Git integration |

Charybdis retains the `appview-worker` directory, executable, and telemetry service key for compatibility.

See [docs/architecture/overview.md](docs/architecture/overview.md) for the full architecture narrative.

## Docs

- **[Test plans](docs/test-plans/README.md)** — verification commands and coverage inventory
- **[Contributing](CONTRIBUTING.md)** — PR workflow and test location conventions
- **[GitHub Wiki](https://github.com/Stygian-Tech/the-social-wire/wiki)** — curated navigation and links into this repository
- **[Lichen Wiki](https://lichen.wiki/@samclemente.me/the-social-wire)** — public user and developer documentation; publish from `docs/wiki/`
- [Architecture overview](docs/architecture/overview.md)
- [Lexicons](docs/architecture/lexicons.md)
- [Discovery chain](docs/architecture/discovery.md)
- [Thin AppView](docs/architecture/appview.md)
- [Redis cache and coordination](docs/architecture/redis.md)
- [Web app](apps/web/README.md)
- [Apple app](apps/apple/README.md)
- [OpenAPI spec](packages/spec/README.md)
- [Lexicon reference](packages/lexicons/README.md)

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE).
