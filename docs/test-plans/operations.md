# Operations and ingestion-recovery test plan

The operator surfaces span the Next.js console, the shared Swift control-plane package, the Operations service, and Jetstream V2 ingestion/recovery evidence. Tap-specific cases are retained as historical compatibility coverage only.

## Local commands

Run from the monorepo root:

```bash
bun install
(cd apps/operations && bun run typecheck && bun run lint && bun run test:coverage)
(cd apps/operations && APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bun run build)
(cd packages/swift/OperationsCore && swift test)
(cd services/operations && swift test)
(cd services/jetstream-ingest && go test ./... && go vet ./...)
```

## CI coverage

| Job | Coverage |
|-----|----------|
| `operations-web` | Operations UI typecheck, lint, coverage-gated tests, and production build |
| `operations` | `OperationsCore` and `services/operations` Swift Testing suites plus the production image build |
| `jetstream-ingest` | Race-enabled Go unit and live-Postgres integration tests, statement coverage gate, vet, and the Jetstream V2 image build |

The Operations UI coverage command also checks `coverage-inventory-allowlist.txt`.
Every production module currently absent from LCOV is reviewed there; a newly
unloaded module or a stale entry fails CI.

## Manual checks

- [ ] Demo mode renders dashboard, gaps, backfills, traces, and runbooks without credentials
- [ ] Hosted OAuth uses the environment's Gateway metadata and operator DID allowlist
- [ ] Railway Development maps `operations.testing.thesocialwire.app` to `api.testing.thesocialwire.app`; Production maps `operations.thesocialwire.app` to `api.thesocialwire.app`
- [ ] Gateway metadata redirects to the matching Operations custom domain, never a generated `*.up.railway.app` domain
- [ ] Production mutations require the exact `PRODUCTION` confirmation and preserve audit evidence
- [ ] Jetstream V2 Ingest holds the environment-scoped fenced lease and Charybdis reports the intended V1/V2 authority mode
- [ ] A mode change produces a non-skipped Charybdis deployment whose startup log reports the intended `jetstream_mode`
- [ ] V2 authority evidence resolves from the durable checkpoint/inbox without requiring a legacy `jetstream` stream row
- [ ] V2 transport freshness comes from the active fenced ingester lease, not projection-owned checkpoint updates
- [ ] V2 backlog alerts use only the advertised source generation while aggregate retained-generation evidence remains visible
- [ ] Charybdis `/readyz` and aggregate Gateway `/readyz` are evaluated independently so an App View or Gateway database failure is not attributed to ingestion

## Related

- [Operations UI](../../apps/operations/README.md)
- [Operations runbooks](../runbooks/operations/README.md)
- [Retired Tap cutover history](../runbooks/operations/tap-shadow-and-cutover.md)
