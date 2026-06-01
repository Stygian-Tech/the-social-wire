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
User's ATProto PDS      Social Wire gateway (optional)
  app.thesocialwire.*     /v1/sync, /v1/appview/*
  site.standard.*         Thin AppView index (EU ams)
       │
       └── Author PDS — entry bodies + canonical read state
```

## Monorepo Structure

```
the-social-wire/
  apps/
    web/         # Next.js 16.2+ web client (Bun)
    apple/       # SwiftUI iOS/iPadOS app
  services/
    gateway/         # OAuth, sync, PDS writes, AppView proxy (Hummingbird; Fly.io)
    appview/         # Publication sidebar + Thin AppView read index (Fly.io)
    appview-worker/  # Jetstream ingestion for Thin AppView (Fly.io)
  packages/
    lexicons/    # app.thesocialwire.* ATProto lexicons
    spec/        # OpenAPI 3.1 spec (gateway + appview routes)
  supabase/
    config.toml  # Supabase CLI; migrations/ for hosted Postgres (see .github/workflows/supabase.yml)
  docs/
    architecture/
    wiki/        # Markdown synced to GitHub Wiki on push to main (see .github/workflows/publish-wiki.yml)
```

## Prerequisites

| Tool | Version |
|------|---------|
| [Bun](https://bun.sh) | Matches root [`package.json`](package.json) `packageManager` (currently 1.3.x) |
| [Swift](https://swift.org/install) | 6.1+ for iOS (`apps/apple`); run `swift test` locally for gateway/appview packages |
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
# Gateway (OAuth, sync, writes)
cd services/gateway && APP_ENV=local swift run Gateway

# AppView (sidebar + Thin AppView reads)
cd services/appview && APP_ENV=local ENABLE_THIN_APPVIEW=true swift run AppView

# AppView worker (Jetstream ingestion)
cd services/appview-worker && APP_ENV=local ENABLE_THIN_APPVIEW=true swift run AppViewWorker

# Supabase (optional — Docker)
supabase start && supabase db reset --local
```

### Running tests

See **[docs/test-plans/README.md](docs/test-plans/README.md)** for per-surface plans and PR checklists.

```bash
cd apps/web && bun test
cd services/gateway && swift test
cd services/appview && swift test
cd services/appview-worker && swift test
cd packages/swift/ThinAppViewCore && swift test

# iOS — Cmd+U in Xcode (see docs/test-plans/apple.md)
```

## Architecture Principles

- **Protocol-first**: user data lives on the user's own ATProto PDS as published records, not in our database
- **PDS-canonical reads**: entry detail and read-state writes target the user's and authors' PDS repos
- **Optional Thin AppView**: when enabled, the gateway indexes Level-1 list rows + read marks in EU Postgres for faster timelines and server-side unread filtering (see [docs/architecture/appview.md](docs/architecture/appview.md))
- **Direct ATProto where it fits**: discovery and repo reads use public XRPC; Bluesky App View (`public.api.bsky.app`) for follows and profiles only
- **Interoperable by design**: lexicons are public — any ATProto client can read a user's Social Wire folders

## Deployment

| Component | Where |
|-----------|-------|
| Web | Vercel (automatic from `main` / `dev` branches) |
| Gateway | Fly.io (`the-social-wire-*-gateway`, **`ams`**) |
| AppView | Fly.io (`the-social-wire-*-appview`, **`ams`**) |
| AppView worker | Fly.io (`the-social-wire-*-appview-worker`, **`ams`**) |
| Database (index + cache) | Supabase Postgres (`supabase/migrations/`) |
| CI/CD | GitHub Actions + Vercel + Fly |

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
