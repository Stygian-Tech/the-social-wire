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
  com.thesocialwire.*     /v1/sync, /v1/appview/*
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
    api/         # Swift gateway (Hummingbird) + optional Thin AppView worker; Fly.io
  packages/
    lexicons/    # com.thesocialwire.* ATProto lexicons
    spec/        # OpenAPI 3.1 spec (service API)
  supabase/
    config.toml  # Supabase CLI; migrations/ for hosted Postgres (see .github/workflows/supabase.yml)
  infra/
    docker/      # docker-compose — builds API from services/api + Caddy + Portainer
  docs/
    architecture/
    wiki/        # Markdown synced to GitHub Wiki on push to main (see .github/workflows/publish-wiki.yml)
```

## Prerequisites

| Tool | Version |
|------|---------|
| [Bun](https://bun.sh) | Matches root [`package.json`](package.json) `packageManager` (currently 1.3.x) |
| [Swift](https://swift.org/install) | 6.1+ for iOS (`apps/apple`); run `swift test` locally for `services/api` |
| [Docker](https://docker.com) | ≥ 25 (optional; local compose stack) |
| [Fly CLI](https://fly.io/docs/flyctl/install/) | Latest (API deploys / ops) |
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

### Running tests

```bash
# TypeScript / React tests
cd apps/web && bun run test

# iOS tests — Cmd+U in Xcode
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
| API | Fly.io (`deploy.yml` — prod + dev apps, **`ams`**) |
| Thin AppView worker | Fly.io separate process (`fly.worker.toml`, `App worker`) |
| Database (index + cache) | Supabase Postgres (`supabase/migrations/`) |
| Local API + TLS | `infra/docker` compose (builds `services/api` Dockerfile) |
| CI/CD | GitHub Actions + Vercel + Fly |

See [docs/architecture/overview.md](docs/architecture/overview.md) for the full architecture narrative.

## Docs

- **[GitHub Wiki](https://github.com/Stygian-Tech/the-social-wire/wiki)** — curated navigation and links into this repository
- [Architecture overview](docs/architecture/overview.md)
- [Lexicons](docs/architecture/lexicons.md)
- [Discovery chain](docs/architecture/discovery.md)
- [Thin AppView](docs/architecture/appview.md)
- [Web app](apps/web/README.md)
- [Apple app](apps/apple/README.md)
- [Gateway API](services/api/README.md)
- [Lexicon reference](packages/lexicons/README.md)

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE).
