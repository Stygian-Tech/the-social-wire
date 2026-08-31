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
    appview-worker/   # AppView worker core + compatibility executable
    indexing-worker/  # Projection Pool and Coordinator roles (Railway)
    operations/       # Operator control plane (Railway)
    jetstream-ingest/ # Multi-lane Ingress Controller (Railway)
  packages/
    lexicons/     # app.thesocialwire.* (and related) lexicons
    spec/         # OpenAPI compatibility contract + endpoint transport manifest
    swift/        # GatewayCore, OperationsCore, SocialWireRedis, ThinAppViewCore
  database/
    migrations/   # Postgres (pds_repo_record_cache, content_items, read_marks, …)
  docs/
    architecture/ # narrative docs (overview, discovery, appview, lexicons)
    runbooks/      # operator incident, recovery, and historical Tap cutover procedures
    test-plans/    # per-surface verification expectations
    wiki/         # canonical public wiki Markdown (GitHub sync; manual Lichen publish)
  .railway/       # IaC partial for consolidated Development indexing services
  railway/        # grandfathered config files for compatibility services
  scripts/        # CI change detection, migration runner, and benchmarks
  .github/workflows/
                  # required CI plus main-only GitHub Wiki publication
```

The shared Swift packages include `GatewayCore`, `OperationsCore`,
`SocialWireRedis`, and `ThinAppViewCore`. Each has its own `Package.swift` and is
tested from its own directory; there is no root Swift package.

The current worker topology is documented in
[docs/architecture/indexing-services.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/indexing-services.md).

**Pointers**

- [Root README](https://github.com/Stygian-Tech/the-social-wire/blob/main/README.md)
- [[Thin-AppView]] — read index, routes, and rollout
- [[Redis]] — disposable cache, coordination, ranking, and rollout
- [[Deployment-and-environments]] — Railway services and environment boundaries
- [[Operations]] — operator console, control plane, ingestion recovery, and runbooks
- [[Testing]] — package commands and CI ownership
