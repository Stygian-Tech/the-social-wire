# Testing

Automated and manual verification for every package in the monorepo.

**Canonical test plans (in-repo):** [docs/test-plans/](https://github.com/Stygian-Tech/the-social-wire/tree/main/docs/test-plans)

## Quick commands

| Surface | Command | CI |
|---------|---------|-----|
| Web | `cd apps/web && bun test` | `web` |
| Operations UI | `cd apps/operations && bun test` | `operations-web` |
| GatewayCore | `cd packages/swift/GatewayCore && swift test` | `gateway` |
| Gateway | `cd services/gateway && swift test` | `gateway` |
| AppView | `cd services/appview && swift test` | `appview` |
| Charybdis | `cd services/appview-worker && swift test` | `charybdis` |
| ThinAppViewCore | `cd packages/swift/ThinAppViewCore && swift test` | `charybdis` |
| OperationsCore | `cd packages/swift/OperationsCore && swift test` | `operations` |
| Operations service | `cd services/operations && swift test` | `operations` |
| Tap image | `docker build --file services/tap/Dockerfile --tag the-social-wire-tap:test .` | `tap` |
| Database migrations | `DATABASE_URL=… bash scripts/apply-database-migrations.sh` | Railway pre-deploy + local validation |
| Lexicons | `cd packages/lexicons && bun test` | `lexicons` |
| OpenAPI spec | `cd packages/spec && bun test` | `spec` |
| iOS | Xcode **Cmd+U** | Local only |

## Per-surface plans

- [Web](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) — Bun, MSW, lib/hooks/API routes
- [Gateway](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/api.md) — Swift Testing, auth, Bruno
- [Charybdis + ThinAppViewCore](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md)
- [Apple](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md) — Swift Testing, OAuth checklist
- [Operations + Tap](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/operations.md)
- [Database migrations](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/database.md) — explicit local validation

## Test location rule

Tests live **inside the owning package** (`apps/web/src/__tests__/`, `services/gateway/Tests/`, etc.). See [[Contributing]].

## Out of scope

Playwright E2E, macOS GitHub Actions, and Xcode Cloud are not configured in this repository.

## Related

- [[Contributing]]
- [CONTRIBUTING.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/CONTRIBUTING.md)
