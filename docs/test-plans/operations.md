# Operations and ingestion-recovery test plan

The operator surfaces span the Next.js console, the shared Swift control-plane package, the Operations service, and Jetstream V2 ingestion/recovery evidence. Tap-specific cases are retained as historical compatibility coverage only.

## Local commands

Run from the monorepo root:

```bash
bun install
(cd apps/operations && bun run typecheck && bun run lint && bun test)
(cd apps/operations && APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bun run build)
(cd packages/swift/OperationsCore && swift test)
(cd services/operations && swift test)
(cd services/jetstream-ingest && go test ./... && go vet ./...)
```

## CI coverage

| Job | Coverage |
|-----|----------|
| `operations-web` | Operations UI typecheck, lint, tests, and production build |
| `operations` | `OperationsCore` and `services/operations` Swift Testing suites |
| `jetstream-ingest` | Go tests, vet, and the Jetstream V2 image build |

## Manual checks

- [ ] Demo mode renders dashboard, gaps, backfills, traces, and runbooks without credentials
- [ ] Hosted OAuth uses the environment's Gateway metadata and operator DID allowlist
- [ ] Railway Development maps `operations.testing.thesocialwire.app` to `api.testing.thesocialwire.app`; Production maps `operations.thesocialwire.app` to `api.thesocialwire.app`
- [ ] Gateway metadata redirects to the matching Operations custom domain, never a generated `*.up.railway.app` domain
- [ ] Production mutations require the exact `PRODUCTION` confirmation and preserve audit evidence
- [ ] Jetstream V2 Ingest holds the environment-scoped fenced lease and Charybdis reports the intended V1/V2 authority mode

## Related

- [Operations UI](../../apps/operations/README.md)
- [Operations runbooks](../runbooks/operations/README.md)
- [Retired Tap cutover history](../runbooks/operations/tap-shadow-and-cutover.md)
