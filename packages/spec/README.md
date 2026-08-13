# OpenAPI spec

OpenAPI compatibility contract and transport manifest for the Social Wire
distributed backend (`services/gateway`, `services/appview`, and
`services/operations`). Lexicon-defined service XRPC schemas live under
`packages/lexicons/app/thesocialwire/`.

**File:** [`openapi.yaml`](./openapi.yaml) (OpenAPI 3.1)

[`endpoint-manifest.json`](./endpoint-manifest.json) is the authoritative transport classification
for every documented operation plus Next.js BFF and private Tap surfaces. `xrpc-migration` entries
name the exact Lexicon NSID; operational, metadata, streaming, media, ATProto-repository,
foreign-service, and vendor-owned HTTP endpoints remain explicitly classified outside XRPC.

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

Asserts documented paths exist in gateway, GatewayCore, AppView, and Operations
router sources, verifies every directly registered literal `/v1/*` path in the
reverse direction, and checks that the endpoint manifest classifies every
OpenAPI operation exactly once.

CI job: **`spec`** (path filter includes `packages/spec/**` and route sources).

## Related

- [Gateway service](../../services/gateway/)
- [AppView service](../../services/appview/)
