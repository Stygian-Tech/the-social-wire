# Monorepo layout

Root folder name (clone path) may vary; structure matches [`the-social-wire`](https://github.com/Stygian-Tech/the-social-wire).

```
the-social-wire/
  apps/
    web/          # Next.js web client (Bun)
    apple/        # SwiftUI iOS/iPadOS
    operations/   # Next.js operator console (Bun)
  services/
    gateway/          # OAuth, sync, PDS writes, AppView proxy (Railway)
    appview/          # Sidebar projection + Thin AppView reads (Railway)
    appview-worker/   # Charybdis: Jetstream ingestion (Railway)
    operations/       # Operator control plane (Railway)
    tap/              # Pinned Indigo Tap image (Railway)
  packages/
    lexicons/     # app.thesocialwire.* (and related) lexicons
    spec/         # OpenAPI compatibility contract + endpoint transport manifest
    swift/        # GatewayCore, OperationsCore, SocialWireRedis, ThinAppViewCore
  database/
    migrations/   # Postgres (pds_repo_record_cache, content_items, read_marks, …)
  docs/
    architecture/ # narrative docs (overview, discovery, appview, lexicons)
    runbooks/      # operator incident, recovery, and Tap cutover procedures
    test-plans/    # per-surface verification expectations
    wiki/         # canonical public wiki Markdown (GitHub sync; manual Lichen publish)
  railway/        # one config-as-code file per deployed service
  scripts/        # CI change detection, migration runner, and benchmarks
  .github/workflows/
                  # required CI plus main-only GitHub Wiki publication
```

The four shared Swift packages are `GatewayCore`, `OperationsCore`,
`SocialWireRedis`, and `ThinAppViewCore`. Each has its own `Package.swift` and is
tested from its own directory; there is no root Swift package.

**Pointers**

- [Root README](https://github.com/Stygian-Tech/the-social-wire/blob/main/README.md)
- [[Thin-AppView]] — read index, routes, and rollout
- [[Redis]] — disposable cache, coordination, ranking, and rollout
- [[Deployment-and-environments]] — Railway services and environment boundaries
- [[Operations]] — operator console, control plane, Tap, and runbooks
- [[Testing]] — package commands and CI ownership
