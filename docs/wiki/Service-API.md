# Service API

Swift Package + Hummingbird gateway under `services/api` — OAuth metadata, authenticated sync accelerators, optional **Thin AppView** read index, and legacy discovery/content routes (gated).

**Runbooks and HTTP contract**

- [services/api/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/services/api/README.md)
- [OpenAPI spec](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml)

## Surfaces (default path)

| Surface | Auth | Flag |
|---------|------|------|
| `GET /health` | None | — |
| `GET /oauth/client-metadata.json`, `/ios-client-metadata.json` | None | — |
| `GET /v1/sync/preferences` | Bearer + DPoP | — |
| `GET /v1/pds/cache/record` | Bearer + DPoP | — |
| **`/v1/appview/*`** | Bearer + DPoP | **`ENABLE_THIN_APPVIEW`** |
| `/discovery/**`, `/publications/**`, `/entries/**` | Bearer + DPoP | **`ENABLE_LEGACY_CONTENT_API`** |

First-party clients only on hosted deploys (`OAUTH_GATEWAY_*` allowlists). See API README.

## Thin AppView (optional)

Level-1 entry index + read-mark replica for server-side unread filtering. **Not** a Bluesky App View proxy.

- **API process:** `App serve` — read routes + enroll + purge
- **Worker process:** `App worker` — Jetstream ingest + TTL cleanup (`fly.worker.toml`)
- **Storage:** Supabase `content_items`, `read_marks` (EU **`ams`**)

Full write-up: [[Thin-AppView]].

## Local development

```bash
cd services/api
cp .env.example .env
APP_ENV=local swift run App          # HTTP server
APP_ENV=local ENABLE_THIN_APPVIEW=true swift run App worker   # ingestion (optional)
swift test
```

CI runs `swift test` in the `test-api` job; run locally when editing this package.

## Related

- [[Thin-AppView]]
- [[Web-app]] / [[Apple-client]] — client flags and gateway usage
