# Operations and Tap test plan

The operator surfaces span the Next.js console, the shared Swift control-plane package, the Operations service, and the pinned Tap image.

## Local commands

Run from the monorepo root:

```bash
bun install
(cd apps/operations && bun run typecheck && bun run lint && bun test)
(cd apps/operations && APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bun run build)
(cd packages/swift/OperationsCore && swift test)
(cd services/operations && swift test)
docker build --file services/tap/Dockerfile --tag the-social-wire-tap:test .
```

## CI coverage

| Job | Coverage |
|-----|----------|
| `operations-web` | Operations UI typecheck, lint, tests, and production build |
| `operations` | `OperationsCore` and `services/operations` Swift Testing suites |
| `tap` | Pinned Tap Docker image builds from the monorepo context |

## Manual checks

- [ ] Demo mode renders dashboard, gaps, backfills, traces, and runbooks without credentials
- [ ] Hosted OAuth uses the environment's Gateway metadata and operator DID allowlist
- [ ] Railway Development maps `operations.testing.thesocialwire.app` to `api.testing.thesocialwire.app`; Production maps `operations.thesocialwire.app` to `api.thesocialwire.app`
- [ ] Gateway metadata redirects to the matching Operations custom domain, never a generated `*.up.railway.app` domain
- [ ] Production mutations require the exact `PRODUCTION` confirmation and preserve audit evidence
- [ ] Charybdis can reach the environment-matched Tap private hostname with authenticated readiness evidence

## Related

- [Operations UI](../../apps/operations/README.md)
- [Operations runbooks](../runbooks/operations/README.md)
- [Tap service](../../services/tap/README.md)
