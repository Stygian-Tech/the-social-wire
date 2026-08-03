# The Social Wire Operations

Dedicated operator console for ingestion health, AppView observability, gaps, backfills, alerts, runbooks, and trace inspection.

## Local Development

```sh
APP_ENV=dev bun --cwd apps/operations dev
```

Set `NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1` for the explicit local demo dataset. Normal operation uses ATProto browser OAuth and the Gateway origins below.

## Environment

- `APP_ENV` — Fixed deployment environment (`dev` or `prod`); forwarded to the browser as `NEXT_PUBLIC_APP_ENV`. Unset deployments default to `dev`; set local overrides in `.env.local`.
- `NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS` — Public comma-delimited operator DID allowlist; `OPERATIONS_OPERATOR_DIDS` is also accepted at build time and forwarded for parity with the Operations service.
- `NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN` — The single Gateway origin for this deployment.
- `NEXT_PUBLIC_OPERATIONS_DEMO_MODE` — Explicit demo mode; never enable in a deployed operator console.

Development and Production are separate Railway services built from `apps/operations`. Configure each service with its fixed environment and matching public Gateway custom domain:

| Environment | Console origin | `APP_ENV` | `NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN` |
|-------------|----------------|-----------|-----------------------------------------|
| Development | `https://operations.testing.thesocialwire.app` | `dev` | `https://api.testing.thesocialwire.app` |
| Production | `https://operations.thesocialwire.app` | `prod` | `https://api.thesocialwire.app` |

The custom domains point at the corresponding Railway services; generated `*.up.railway.app` domains are deployment diagnostics, not OAuth client origins. Hosted OAuth uses `${NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN}/operations-oauth-client-metadata.json`, whose redirect URI must match the console origin above. The same-origin `/operations-client-metadata.json` route remains a local-development fallback. Configure the operator DID allowlist independently in each environment; the console does not switch environments at runtime.

Backfill creation is dry-run-first. Operator notes are optional; every mutation carries idempotency and expected-version evidence, and Production additionally requires the exact `PRODUCTION` confirmation. Authorization is enforced by the operations service DID allowlist.

## Testing

From the monorepo root:

```sh
bun install
bunx turbo typecheck lint test --filter=operations
APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bunx turbo build --filter=operations
```

CI runs the same checks in **`operations-web`**. Swift control-plane and Tap verification commands are in the [Operations and Tap test plan](../../docs/test-plans/operations.md).
