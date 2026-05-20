# OpenAPI spec

HTTP contract for the Social Wire gateway (`services/api`).

**File:** [`openapi.yaml`](./openapi.yaml) (OpenAPI 3.1)

## Purpose

Documents first-party routes:

- Health and OAuth metadata
- `/v1/sync/*` and `/v1/pds/cache/*`
- `/v1/appview/*` (when `ENABLE_THIN_APPVIEW=true`)
- Legacy discovery/content routes (when `ENABLE_LEGACY_CONTENT_API=true`)

Bruno collections under `services/api/bruno/` mirror these routes for manual verification.

## Server URLs

The `servers` block lists hosted environments. Production uses `api.thesocialwire.app`; local dev is typically `http://127.0.0.1:8080`.

## Drift check

```bash
cd packages/spec
bun test
```

Asserts documented paths exist in `services/api/Sources/App/**/*.swift`.

CI job: **`test-spec`** (path filter includes `packages/spec/**` and API route sources).

## Related

- [API README](../../services/api/README.md)
- [API test plan](../../docs/test-plans/api.md)
