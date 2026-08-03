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

Production deploys to the Vercel project rooted at `apps/operations`; Development deploys in the isolated Railway `dev` environment. Production must configure `APP_ENV=prod`, while Railway Development uses `APP_ENV=dev`. Configure the corresponding Gateway origin and operator DID allowlist per environment; the console does not switch environments at runtime. Hosted deployments use the public Gateway's `/operations-oauth-client-metadata.json` document so OAuth works when the UI deployment is protected. The same-origin `/operations-client-metadata.json` route remains available as a fallback.

Backfill creation is dry-run-first. Operator notes are optional; every mutation carries idempotency and expected-version evidence, and Production additionally requires the exact `PRODUCTION` confirmation. Authorization is enforced by the operations service DID allowlist.

## Testing

From the monorepo root:

```sh
bun install
bunx turbo typecheck lint test --filter=operations
APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bunx turbo build --filter=operations
```

CI runs the same checks in **`build-operations`**. Swift control-plane and Tap verification commands are in the [Operations and Tap test plan](../../docs/test-plans/operations.md).
