# Test plans

Verification guides for each surface in the monorepo. Tests live **in the owning package** (never a root-level `tests/` folder).

| Surface | Plan | Command | CI job |
|---------|------|---------|--------|
| Web | [web.md](./web.md) | `cd apps/web && bun test` | `build-web` |
| Operations UI | [operations.md](./operations.md) | `cd apps/operations && bun test` | `build-operations` |
| GatewayCore | [api.md](./api.md) | `cd packages/swift/GatewayCore && swift test` | `test-gateway` |
| Gateway | [api.md](./api.md) | `cd services/gateway && swift test` | `test-gateway` |
| AppView | [appview.md](./appview.md) | `cd services/appview && swift test` | `test-appview` |
| Charybdis | [worker.md](./worker.md) | `cd services/appview-worker && swift test` | `test-appview-worker` |
| ThinAppViewCore | [worker.md](./worker.md#thinappviewcore) | `cd packages/swift/ThinAppViewCore && swift test` | `test-appview-worker` |
| OperationsCore | [operations.md](./operations.md) | `cd packages/swift/OperationsCore && swift test` | `test-operations` |
| Operations service | [operations.md](./operations.md) | `cd services/operations && swift test` | `test-operations` |
| Tap image | [operations.md](./operations.md) | `docker build --file services/tap/Dockerfile --tag the-social-wire-tap:test .` | `test-tap-image` |
| iOS | [apple.md](./apple.md) | Xcode **Cmd+U** | Local only (Xcode Cloud deferred) |
| Supabase | [supabase.md](./supabase.md) | `supabase db reset --local` | `supabase-validate` |
| Lexicons | [web.md](./web.md#lexicons) | `cd packages/lexicons && bun test` | `test-lexicons` |
| OpenAPI spec | [api.md](./api.md#openapi-drift) | `cd packages/spec && bun test` | `test-spec` |

## Run all automated tests locally

From the monorepo root (requires Swift 6.2+ and Bun):

```bash
bun install

# Web
cd apps/web && bun test && cd ../..

# Operations UI
cd apps/operations && bun test && cd ../..

# Backend services
cd packages/swift/GatewayCore && swift test && cd ../../..
cd services/gateway && swift test && cd ../..
cd services/appview && swift test && cd ../..
cd services/appview-worker && swift test && cd ../..
cd packages/swift/OperationsCore && swift test && cd ../../..
cd services/operations && swift test && cd ../..

# ThinAppViewCore
cd packages/swift/ThinAppViewCore && swift test && cd ../../..

# Lexicons + OpenAPI drift
cd packages/lexicons && bun test && cd ../..
cd packages/spec && bun test && cd ../..

# Tap image
docker build --file services/tap/Dockerfile --tag the-social-wire-tap:test .

# Supabase migration validation (requires Docker)
supabase db start --yes
supabase db reset --local --yes --no-seed
supabase stop --no-backup --yes
```

## PR checklist

- [ ] Logic changes include tests in the **same package** as the source
- [ ] `bun test` / `swift test` pass for affected packages
- [ ] Test plan doc updated if scope or commands changed
- [ ] Wiki `docs/wiki/Testing.md` updated for new coverage areas (when applicable)
- [ ] No secrets in test fixtures or committed env files

## Out of scope (handled separately)

- Playwright / browser E2E
- macOS GitHub Actions or Xcode Cloud for iOS
- Coverage percentage gates in CI

## Branch protection

Require the **`CI — Required`** job from `.github/workflows/ci.yml`. It aggregates path-filtered jobs and fails when any required check for changed paths did not succeed.

## Related

- [CONTRIBUTING.md](../../CONTRIBUTING.md)
- [Architecture overview](../architecture/overview.md)
- [GitHub Wiki — Testing](../wiki/Testing.md)
