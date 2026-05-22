# OpenAPI spec

HTTP contract for the Social Wire distributed backend (`services/gateway` + `services/appview`).

**File:** [`openapi.yaml`](./openapi.yaml) (OpenAPI 3.1)

## Purpose

Documents first-party routes:

- Health and OAuth metadata (gateway)
- `/v1/sync/*` and `/v1/pds/cache/*` (gateway)
- `/v1/publications/*` and `/v1/reader/*` (gateway writes; appview reads when proxied)
- `/v1/appview/*` (appview, when `ENABLE_THIN_APPVIEW=true`)

Bruno collections for manual verification:

- `services/gateway/bruno/` — gateway routes (OAuth, sync, publications, reader, AppView proxy)
- `services/appview/bruno/` — AppView routes (sidebar + Thin AppView index)
- `services/appview-worker/bruno/` — post-ingestion verification (worker has no HTTP API)

## Server URLs

The `servers` block lists hosted environments. Production gateway is `api.thesocialwire.app`; local dev is typically `http://127.0.0.1:8080`.

## Drift check

```bash
cd packages/spec
bun test
```

Asserts documented paths exist in gateway, GatewayCore, and appview router sources.

CI job: **`test-spec`** (path filter includes `packages/spec/**` and route sources).

## Related

- [Gateway service](../../services/gateway/)
- [AppView service](../../services/appview/)
