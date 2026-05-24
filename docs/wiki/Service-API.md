# Service API

Distributed Swift/Hummingbird backend under **`services/gateway`**, **`services/appview`**, and **`services/appview-worker`**.

**HTTP contract:** [packages/spec/openapi.yaml](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Surfaces

| Service | Role | Public routes |
|---------|------|---------------|
| **Gateway** | OAuth metadata, DPoP verification, PDS write-through, sync cache, AppView proxy | `/health`, `/oauth/*`, `/v1/sync/*`, `/v1/pds/cache/*`, `/v1/publications/folders|prefs|subscriptions|…`, `/v1/reader/*`, proxied `/v1/publications/sidebar|refresh|resolve`, proxied `/v1/appview/*` |
| **AppView** | Sidebar projection, Thin AppView read index, bootstrap stream | `/v1/publications/sidebar|refresh|resolve`, `/v1/appview/*` (when **`ENABLE_THIN_APPVIEW`**) |
| **AppView worker** | Jetstream ingestion, proactive backfill, TTL cleanup | No HTTP API |

Gateway→AppView calls use **`GATEWAY_APPVIEW_INTERNAL_SECRET`** HMAC trust headers so AppView can skip JWT re-verification on proxied requests. Clients always hit the **gateway** host (`api.thesocialwire.app` / `api.testing.thesocialwire.app`).

First-party clients only on hosted deploys (`OAUTH_GATEWAY_*` allowlists).

## Local development

```bash
# Gateway (OAuth, sync, writes, AppView proxy)
cd services/gateway && APP_ENV=local APPVIEW_BASE_URL=http://127.0.0.1:8081 swift run Gateway

# AppView (sidebar + Thin AppView reads)
cd services/appview && APP_ENV=local ENABLE_THIN_APPVIEW=true swift run AppView

# AppView worker (Jetstream ingestion — optional locally)
cd services/appview-worker && APP_ENV=local ENABLE_THIN_APPVIEW=true swift run AppViewWorker

swift test   # per service directory
```

Set **`APPVIEW_BASE_URL`** on the gateway when running AppView on a separate port. Local mode uses SQLite unless **`SUPABASE_DATABASE_URL`** is set.

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
| `test-spec` | OpenAPI drift vs gateway + appview route sources |

## Related

- [[Thin-AppView]] — flags, routes, deployment
- [[ThinAppViewCore]] — shared indexing library
- [[Web-app]] / [[Apple-client]] — client integration
