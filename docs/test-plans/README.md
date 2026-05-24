# Test plans

Verification guides for each surface in the monorepo. Tests live **in the owning package** (never a root-level `tests/` folder).

| Surface | Plan | Command | CI job |
|---------|------|---------|--------|
| Web | [web.md](./web.md) | `cd apps/web && bun test` | `build-web` |
| Gateway | [api.md](./api.md) | `cd services/gateway && swift test` | `test-gateway` |
| AppView | [appview.md](./appview.md) | `cd services/appview && swift test` | `test-appview` |
| AppView worker | [worker.md](./worker.md) | `cd services/appview-worker && swift test` | `test-appview-worker` |
| ThinAppViewCore | [worker.md](./worker.md#thinappviewcore) | `cd packages/swift/ThinAppViewCore && swift test` | `test-appview`, `test-appview-worker` |
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

# Backend services
cd services/gateway && swift test && cd ../..
cd services/appview && swift test && cd ../..
cd services/appview-worker && swift test && cd ../..

# ThinAppViewCore
cd packages/swift/ThinAppViewCore && swift test && cd ../../..

# Lexicons + OpenAPI drift
cd packages/lexicons && bun test && cd ../..
cd packages/spec && bun test && cd ../..
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

Require the **`CI — required`** job from `.github/workflows/ci.yml`. It aggregates path-filtered jobs and fails when any required check for changed paths did not succeed.

## Related

- [CONTRIBUTING.md](../../CONTRIBUTING.md)
- [Architecture overview](../architecture/overview.md)
- [GitHub Wiki — Testing](../wiki/Testing.md)
