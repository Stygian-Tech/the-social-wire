# OpenAPI spec

HTTP contract for the Social Wire distributed backend (`services/gateway`, `services/appview`, and `services/operations`).

**File:** [`openapi.yaml`](./openapi.yaml) (OpenAPI 3.1)

## Purpose

Documents first-party routes:

- Health and OAuth metadata (gateway)
- `/v1/sync/*` and `/v1/pds/cache/*` (gateway)
- `/v1/publications/*`, `/v1/latr/*`, and `/v1/telemetry/*` (gateway)
- `/v1/appview/*` (appview, when `ENABLE_THIN_APPVIEW=true`)
- `/v1/operations/*` (operations service, proxied by gateway)

Bruno collections for manual verification:

- `services/gateway/bruno/` — gateway routes (OAuth, sync, publications, L@tr, Operations, telemetry, AppView proxy)
- `services/appview/bruno/` — AppView routes (sidebar + Thin AppView index)
- `services/appview-worker/bruno/` — Charybdis post-ingestion verification (the service has no HTTP API)

## Server URLs

The `servers` block lists hosted environments. Production gateway is `api.thesocialwire.app`; local dev is typically `http://127.0.0.1:8080`.

## Drift check

```bash
cd packages/spec
bun test
```

Asserts documented paths exist in gateway, GatewayCore, AppView, and Operations router sources.

CI job: **`test-spec`** (path filter includes `packages/spec/**` and route sources).

## Related

- [Gateway service](../../services/gateway/)
- [AppView service](../../services/appview/)
