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
User's ATProto PDS      Social Wire gateway (Fly, iah)
  app.thesocialwire.*     /v1/sync, /v1/publications/*
  link.latr.saved.*       /v1/appview/*, /v1/latr/*
                               │
                               └── AppView + Charybdis
                                   Postgres (AWS us-east-1)
```

## Monorepo Structure

```
the-social-wire/
  apps/
    web/             # Next.js 16.2+ reader (Bun)
    apple/           # SwiftUI iOS/iPadOS app
    operations/      # Next.js operator console (Bun)
  services/
    gateway/         # OAuth, sync, PDS writes, AppView proxy (Hummingbird; Fly.io)
    appview/         # Publication sidebar + Thin AppView read index (Fly.io)
    appview-worker/  # Charybdis: Jetstream ingestion for Thin AppView (Fly.io)
    operations/      # Operations control plane (Fly.io)
    tap/             # Pinned Indigo Tap image (Fly.io)
  packages/
    lexicons/        # app.thesocialwire.* and L@tr ATProto lexicons
    spec/            # OpenAPI 3.1 spec
    swift/           # GatewayCore, OperationsCore, ThinAppViewCore
  supabase/
    config.toml      # Supabase CLI; migrations run from .github/workflows/ci.yml
  docs/
    architecture/
    wiki/        # Markdown synced to GitHub Wiki on push to main (see .github/workflows/publish-wiki.yml)
```

## Prerequisites

| Tool | Version |
|------|---------|
| [Bun](https://bun.sh) | Matches root [`package.json`](package.json) `packageManager` (currently 1.3.x) |
| [Swift](https://swift.org/install) | 6.2+ for service/package test parity (CI uses 6.2.4) |
| [Fly CLI](https://fly.io/docs/flyctl/install/) | Latest (Fly deploys / ops) |
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

```bash
# Run each service in a separate terminal.
# Gateway (OAuth, sync, writes)
(cd services/gateway && APP_ENV=local APPVIEW_BASE_URL=http://127.0.0.1:8081 GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run Gateway)

# AppView (sidebar + Thin AppView reads)
(cd services/appview && APP_ENV=local ENABLE_THIN_APPVIEW=true SQLITE_DB_PATH=/tmp/the-social-wire-appview.sqlite GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run AppView)

# Charybdis (Jetstream ingestion)
(cd services/appview-worker && APP_ENV=local ENABLE_THIN_APPVIEW=true SQLITE_DB_PATH=/tmp/the-social-wire-appview.sqlite swift run AppViewWorker)

# Migration validation (optional — Docker; local services above use SQLite)
supabase start && supabase db reset --local
```

### Running tests

See **[docs/test-plans/README.md](docs/test-plans/README.md)** for per-surface plans and PR checklists.

```bash
(cd apps/web && bun test)
(cd apps/operations && bun test)
(cd packages/swift/GatewayCore && swift test)
(cd services/gateway && swift test)
(cd services/appview && swift test)
(cd packages/swift/ThinAppViewCore && swift test)
(cd services/appview-worker && swift test)
(cd packages/swift/OperationsCore && swift test)
(cd services/operations && swift test)

# iOS — Cmd+U in Xcode (see docs/test-plans/apple.md)
```

## Architecture Principles

- **Protocol-first where data is portable**: folders, publication preferences, subscriptions, and read-later records live on the user's own ATProto PDS
- **AppView-owned read state**: feed read/unread state is local-first in clients and synchronized to Social Wire AppView for counters and unread filtering
- **Thin AppView read path**: signed-in clients load bootstrap data, feeds, and entry detail through the gateway-backed AppView; standard.site bodies remain authoritative on publisher PDSes, while RSS feed bodies may be retained in the derived index (see [docs/architecture/appview.md](docs/architecture/appview.md))
- **Direct ATProto where it fits**: discovery and repo reads use public XRPC; Bluesky App View (`public.api.bsky.app`) for follows and profiles only
- **Interoperable by design**: lexicons are public — any ATProto client can read a user's Social Wire folders

## Deployment

| Component | Where |
|-----------|-------|
| Web + Operations UI | Separate Vercel projects (automatic from `main` / `dev`) |
| Gateway | Fly.io (`the-social-wire-*-gateway`, **`iah`**) |
| AppView | Fly.io (`the-social-wire-*-appview`, **`iah`**) |
| Charybdis | Fly.io (`the-social-wire-*-appview-worker`, **`iah`**) |
| Operations + Tap | Fly.io (development automatic; production rollout is manual, **`iah`**) |
| Database (index + cache) | Supabase Postgres (`supabase/migrations/`) |
| CI/CD | GitHub Actions + Vercel + Fly |

Charybdis retains the `appview-worker` directory, executable, Fly app names, CI identifiers, and telemetry service key for deployment and historical-observability compatibility.

See [docs/architecture/overview.md](docs/architecture/overview.md) for the full architecture narrative.

## Docs

- **[Test plans](docs/test-plans/README.md)** — verification commands and coverage inventory
- **[Contributing](CONTRIBUTING.md)** — PR workflow and test location conventions
- **[GitHub Wiki](https://github.com/Stygian-Tech/the-social-wire/wiki)** — curated navigation and links into this repository
- [Architecture overview](docs/architecture/overview.md)
- [Lexicons](docs/architecture/lexicons.md)
- [Discovery chain](docs/architecture/discovery.md)
- [Thin AppView](docs/architecture/appview.md)
- [Web app](apps/web/README.md)
- [Apple app](apps/apple/README.md)
- [OpenAPI spec](packages/spec/README.md)
- [Lexicon reference](packages/lexicons/README.md)

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE).
