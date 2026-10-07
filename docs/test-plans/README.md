# Test plans

Verification guides for each surface in the monorepo. Tests live **in the owning package** (never a root-level `tests/` folder).

| Surface | Plan | Command | CI job |
|---------|------|---------|--------|
| Web | [web.md](./web.md) | `cd apps/web && bun run test:coverage` | `web` |
| Operations UI | [operations.md](./operations.md) | `cd apps/operations && bun run test:coverage` | `operations-web` |
| SocialWireRedis | [appview.md](./appview.md#redis-cache-and-coordination) | `cd packages/swift/SocialWireRedis && swift test` | `redis` |
| GatewayCore | [api.md](./api.md) | `cd packages/swift/GatewayCore && swift test` | `shared-swift` |
| Gateway | [api.md](./api.md) | `cd services/gateway && go test -race ./...` | `go-packages` |
| AppView | [appview.md](./appview.md) | `cd services/appview && go test -race ./...` | `go-packages` |
| Replicated indexing roles | [worker.md](./worker.md) | `cd services/indexing-worker && go test -race ./...` | `indexing-worker` |
| ThinAppViewCore | [worker.md](./worker.md#thinappviewcore) | `cd packages/swift/ThinAppViewCore && swift test` | `shared-swift` |
| OperationsCore | [operations.md](./operations.md) | `cd packages/swift/OperationsCore && swift test` | `shared-swift` / `go-packages` |
| Operations service | [operations.md](./operations.md) | `cd services/operations && go test -race ./...` | `shared-swift` / `go-packages` |
| Jetstream V2 Ingest | [operations.md](./operations.md) | `(cd services/jetstream-ingest && go test ./... && go vet ./...)` | `jetstream-ingest` |
| iOS | [apple.md](./apple.md) | Xcode **Cmd+U** | `apple` |
| Database migrations | [database.md](./database.md) | `DATABASE_URL=… bash scripts/apply-database-migrations.sh` | `database-migrator` (empty DB + idempotence) |
| Lexicons | [web.md](./web.md#lexicons) | `cd packages/lexicons && bun test` | `lexicons` |
| OpenAPI spec | [api.md](./api.md#openapi-drift) | `cd packages/spec && bun test` | `spec` |

## Run all automated tests locally

From the monorepo root (requires Go 1.26, Swift 6.2+ and Bun):

```bash
bun install

# Web
cd apps/web && bun run test:coverage && cd ../..

# Operations UI
cd apps/operations && bun run test:coverage && cd ../..

# Backend services
cd packages/swift/SocialWireRedis && swift test && cd ../../..
cd packages/swift/GatewayCore && swift test && cd ../../..
cd services/gateway && go test -race ./... && cd ../..
cd services/appview && go test -race ./... && cd ../..
cd services/indexing-worker && go test -race ./... && cd ../..
cd packages/swift/OperationsCore && swift test && cd ../../..
cd services/operations && go test -race ./... && cd ../..

# ThinAppViewCore
cd packages/swift/ThinAppViewCore && swift test && cd ../../..

# Lexicons + OpenAPI drift
cd packages/lexicons && bun test && cd ../..
cd packages/spec && bun test && cd ../..

# Jetstream V2 Ingest
(cd services/jetstream-ingest && go test ./... && go vet ./...)

# Database migration validation (use a disposable Postgres database)
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

## PR checklist

- [ ] Logic changes include tests in the **same package** as the source
- [ ] `bun test` / `swift test` pass for affected packages
- [ ] Test plan doc updated if scope or commands changed
- [ ] Wiki `docs/wiki/Testing.md` updated for new coverage areas (when applicable)
- [ ] No secrets in test fixtures or committed env files

## Out of scope (handled separately)

- Playwright / browser E2E
- Authenticated browser end-to-end automation
- Live hosted-database mutation from GitHub Actions

## Branch protection

Require the **`CI — Required`** job from `.github/workflows/ci.yml` on both `dev` and `main`. It aggregates path-filtered jobs and fails when any required check for changed paths did not succeed.

## Related

- [CONTRIBUTING.md](../../CONTRIBUTING.md)
- [Architecture overview](../architecture/overview.md)
- [GitHub Wiki — Testing](../wiki/Testing.md)
