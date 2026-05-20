# Testing

Automated and manual verification for every package in the monorepo.

**Canonical test plans (in-repo):** [docs/test-plans/](https://github.com/Stygian-Tech/the-social-wire/tree/main/docs/test-plans)

## Quick commands

| Surface | Command | CI |
|---------|---------|-----|
| Web | `cd apps/web && bun test` | `build-web` |
| API | `cd services/api && swift test` | `test-api` |
| Worker | `cd services/worker && swift test` | `test-worker` |
| ThinAppViewCore | `cd packages/swift/ThinAppViewCore && swift test` | `test-api`, `test-worker` |
| Lexicons | `cd packages/lexicons && bun test` | `test-lexicons` |
| OpenAPI spec | `cd packages/spec && bun test` | `test-spec` |
| iOS | Xcode **Cmd+U** | Local only |

## Per-surface plans

- [Web](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) — Bun, MSW, lib/hooks/API routes
- [API](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/api.md) — Swift Testing, auth matrix, Bruno
- [Worker](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/worker.md) — worker CLI + ThinAppViewCore
- [Apple](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md) — Swift Testing, OAuth checklist
- [Supabase](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/supabase.md) — migrations, CI validate

## Test location rule

Tests live **inside the owning package** (`apps/web/src/__tests__/`, `services/api/Tests/`, etc.). See [[Contributing]].

## Out of scope

Playwright E2E, macOS GitHub Actions, and Xcode Cloud are not configured in this repository.

## Related

- [[Contributing]]
- [CONTRIBUTING.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/CONTRIBUTING.md)
