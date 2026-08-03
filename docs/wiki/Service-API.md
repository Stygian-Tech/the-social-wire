# Service API

Distributed backend under **`services/gateway`**, **`services/appview`**, **`services/appview-worker`**, **`services/operations`**, and **`services/tap`**.

**HTTP contract:** [packages/spec/openapi.yaml](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Surfaces

| Service | Role | Public routes |
|---------|------|---------------|
| **Gateway** | OAuth metadata, DPoP verification, PDS write-through, sync cache, AppView/Operations proxies | `/health`, `/oauth/*`, `/v1/sync/*`, `/v1/pds/cache/*`, `/v1/publications/*`, `/v1/latr/*`, `/v1/telemetry/*`, proxied `/v1/appview/*` and `/v1/operations/*` |
| **AppView** | Sidebar projection, Thin AppView read index, bootstrap stream | `/v1/publications/sidebar|refresh|resolve`, `/v1/appview/*` (when **`ENABLE_THIN_APPVIEW`**) |
| **Charybdis** | Jetstream/Tap ingestion, Skyreader RSS polling, proactive backfill, TTL cleanup | No HTTP API |
| **Operations** | Operator-only observability, gaps, backfills, traces, and audited controls | Internal operations routes proxied through Gateway |
| **Tap** | Pinned Indigo Tap synchronization service used by Charybdis | Private authenticated Tap API |

Gateway→AppView calls use **`GATEWAY_APPVIEW_INTERNAL_SECRET`** HMAC trust headers so AppView can skip JWT re-verification on proxied requests. Clients always hit the **gateway** host (`api.thesocialwire.app` / `api.testing.thesocialwire.app`).

First-party clients only on hosted deploys (`OAUTH_GATEWAY_*` allowlists).

## Local development

```bash
# Run each long-lived service in a separate terminal.
# Gateway (OAuth, sync, writes, AppView proxy)
(cd services/gateway && APP_ENV=local APPVIEW_BASE_URL=http://127.0.0.1:8081 GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run Gateway)

# AppView (sidebar + Thin AppView reads)
(cd services/appview && APP_ENV=local ENABLE_THIN_APPVIEW=true SQLITE_DB_PATH=/tmp/the-social-wire-appview.sqlite GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run AppView)

# Charybdis (Jetstream ingestion — optional locally)
(cd services/appview-worker && APP_ENV=local ENABLE_THIN_APPVIEW=true SQLITE_DB_PATH=/tmp/the-social-wire-appview.sqlite swift run AppViewWorker)

# Operations control plane
(cd services/operations && APP_ENV=dev SUPABASE_DATABASE_URL='postgresql://…' swift run Operations)

# Tests run from each service/package directory with `swift test`.
```

Set **`APPVIEW_BASE_URL`** on Gateway and point local AppView plus Charybdis at the same absolute **`SQLITE_DB_PATH`** so worker ingestion is visible to reads. Gateway/AppView/Charybdis local mode uses SQLite; Operations is intentionally environment-scoped and requires Postgres.

## Bruno collections

- `services/gateway/bruno/` — gateway routes + AppView proxy smoke tests
- `services/appview/bruno/` — AppView-only routes (sidebar, bootstrap stream, entries)
- `services/appview-worker/bruno/` — post-ingestion verification notes (worker has no HTTP)

## CI

| Job | Package |
|-----|---------|
| `test-gateway` | `services/gateway` |
| `test-appview` | `services/appview` |
| `test-appview-worker` | `services/appview-worker` |
| `test-operations` | `packages/swift/OperationsCore` + `services/operations` |
| `test-tap-image` | Pinned `services/tap/Dockerfile` image build |
| `test-spec` | OpenAPI drift vs gateway + appview route sources |

## Related

- [[Thin-AppView]] — flags, routes, deployment
- [[ThinAppViewCore]] — shared indexing library
- [[Web-app]] / [[Apple-client]] — client integration
