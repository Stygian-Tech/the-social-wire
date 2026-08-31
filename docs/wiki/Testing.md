# Testing

Automated and manual verification for every package in the monorepo.

**Canonical test plans (in-repo):** [docs/test-plans/](https://github.com/Stygian-Tech/the-social-wire/tree/main/docs/test-plans)

## Quick commands

| Surface | Command | CI |
|---------|---------|-----|
| Web | `cd apps/web && bun run test:coverage` | `web` |
| Operations UI | `cd apps/operations && bun run test:coverage` | `operations-web` |
| SocialWireRedis | `cd packages/swift/SocialWireRedis && swift test` | `redis` |
| GatewayCore | `cd packages/swift/GatewayCore && swift test` | `gateway` |
| Gateway | `cd services/gateway && swift test` | `gateway` |
| AppView | `cd services/appview && swift test` | `appview` |
| Charybdis | `cd services/appview-worker && swift test` | `charybdis` |
| Replicated indexing roles | `cd services/indexing-worker && swift test` | `indexing-worker` |
| ThinAppViewCore | `cd packages/swift/ThinAppViewCore && swift test` | `charybdis` |
| OperationsCore | `cd packages/swift/OperationsCore && swift test` | `operations` |
| Operations service | `cd services/operations && swift test` | `operations` |
| Jetstream V2 Ingest | `(cd services/jetstream-ingest && go test ./... && go vet ./...)` | `jetstream-ingest` |
| Database migrations | `DATABASE_URL=… bash scripts/apply-database-migrations.sh` | `database-migrator` (empty DB + idempotence) |
| Lexicons | `cd packages/lexicons && bun test` | `lexicons` |
| OpenAPI spec | `cd packages/spec && bun test` | `spec` |
| iOS | Xcode **Cmd+U** | `apple` |

## Per-surface plans

- [Web](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) — Bun, MSW, lib/hooks/API routes
- [Gateway](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/api.md) — Swift Testing, auth, Bruno
- [Charybdis + ThinAppViewCore](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md)
- [Apple](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md) — Swift Testing, OAuth checklist
- [Operations](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/operations.md)
- [Database migrations](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/database.md) — explicit local validation

## Test location rule

Tests live **inside the owning package** (`apps/web/src/__tests__/`, `services/gateway/Tests/`, etc.). See [[Contributing]].

## Full CI gate

The single `.github/workflows/ci.yml` workflow detects changed paths and runs the relevant Web, Operations Web, Apple, Redis, Gateway, AppView, compatibility worker, replicated indexing worker, Operations, Ingress Controller, database migration, Lexicon, OpenAPI, and documentation jobs. **CI — Required** is the aggregate branch-protection check. OpenAPI drift coverage checks both documented-to-source mappings and every directly registered literal `/v1/*` source path. GitHub Actions validates source only; Railway's Git integration is responsible for deployments.

Documentation-only changes should still run the wiki integrity checker and
`git diff --check`. The main-only publish workflow runs the same checker before
syncing `docs/wiki/` to the GitHub Wiki.

## Out of scope

Authenticated Playwright E2E and Xcode Cloud remain out of scope. GitHub Actions
runs iOS tests with Xcode coverage and enforces measured Bun and Go coverage
baselines; percentages are non-regression floors, not whole-application claims.

## Related

- [[Contributing]]
- [CONTRIBUTING.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/CONTRIBUTING.md)
