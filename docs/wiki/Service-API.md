# Services and API

Clients call the public **Gateway** host. AppView, Operations, databases, and worker traffic stay on Railway private networking.

**Machine-readable contracts:**
[OpenAPI](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/openapi.yaml),
[endpoint transport manifest](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/endpoint-manifest.json),
and [service Lexicons](https://github.com/Stygian-Tech/the-social-wire/tree/main/packages/lexicons/app/thesocialwire).

Eligible authenticated JSON queries and procedures use
`/xrpc/app.thesocialwire.*`, with `/v1/*` compatibility routes retained.

Streaming, health/readiness, OAuth metadata, telemetry, and vendor-owned
transports stay HTTP. User-owned records use standard `com.atproto.repo.*`
XRPC directly on the viewer PDS.
L@tr exposes its foreign bookmark XRPC surface unchanged.
The endpoint manifest records the intended transport per operation.

## Service boundaries

| Service | Role | HTTP surface |
|---------|------|--------------|
| **Gateway** | OAuth metadata, DPoP verification, sync/PDS acceleration, AppView/L@tr/Operations proxy | Public health/metadata, `/xrpc/app.thesocialwire.*`, and retained `/v1/*` adapters |
| **AppView** | Sidebar projection, indexed reads, unread state, bootstrap stream | Private `/xrpc/app.thesocialwire.*`, retained `/v1/*` adapters, and NDJSON bootstrap |
| **Charybdis** | Jetstream ingestion and durable-inbox projection, RSS polling, backfill, repair, TTL cleanup | No application HTTP API |
| **Jetstream V2 Ingest** | Fenced Jetstream subscription and durable PostgreSQL inbox staging | Private health/readiness only |
| **Operations** | Operator evidence and controlled recovery | Private `/v1/operations/*`, proxied by Gateway; pending source adds Operations XRPC aliases |

## Gateway compatibility route groups

| Group | Purpose |
|-------|---------|
| OAuth metadata | Web, Apple, and Operations client registrations |
| `/v1/sync/*` | Preferences envelope and legacy Social Wire lexicon migration |
| `/v1/pds/cache/*` | Short-lived single-record read acceleration |
| `/v1/publications/*` | Sidebar proxy, resolve/refresh, and native PDS write-through |
| `/v1/appview/*` | Bootstrap, feeds, entry detail, unread counts, read mutations, enrollment, purge |
| `/xrpc/link.latr.bookmarks.*` | Native L@tr bookmark queries, mutations, and migration proxy |
| `/v1/telemetry/*` | Bounded, deidentified client-performance samples |
| `/v1/operations/*` | Operator-only control-plane proxy |

Examples in the XRPC surface include
`app.thesocialwire.sync.getPreferences`,
`app.thesocialwire.publication.getSidebar`,
`app.thesocialwire.appview.getFeed`, and
`app.thesocialwire.operations.getOverview`. Query inputs use the URL query
string; procedures use JSON request bodies. XRPC errors use the standard
`{"error":"Name","message":"..."}` envelope.

AppView proxy routes mount only when `APPVIEW_BASE_URL` is configured. Operations routes require `OPERATIONS_BASE_URL` and a distinct `GATEWAY_OPERATIONS_INTERNAL_SECRET`. Native L@tr XRPC routes mount only when the server-side `LATR_IOS_PROXY_*` credentials are configured.

Gateway→AppView trust uses `GATEWAY_APPVIEW_INTERNAL_SECRET`, with HMAC over the request path. Gateway→Operations uses its separate Operations secret. External clients must never send or know either internal secret.

## Authentication and authorization

Authenticated routes accept an ATProto OAuth access token and a request-bound RFC 9449 DPoP proof. A gateway-bound DPoP proof cannot be forwarded to a PDS or L@tr origin; native write-through paths use distinct upstream proof headers.

Known-client enforcement is conditional on `OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT`. When enabled, token claims must match the configured client-ID and/or audience allowlists. Operations routes additionally enforce `OPERATIONS_OPERATOR_DIDS`.

## Local integration

The current Gateway, AppView, and Charybdis executables reject `APP_ENV=local` through the shared Operations environment guard even though SQLite backends remain implemented. Use an isolated disposable Postgres database and `APP_ENV=dev` until that mismatch is fixed.

```bash
# Apply migrations to a disposable database first.
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh

# Terminal 1: AppView
cd services/appview
APP_ENV=dev DATABASE_URL='postgresql://…' ENABLE_THIN_APPVIEW=true \
  GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run AppView

# Terminal 2: Gateway
cd services/gateway
APP_ENV=dev DATABASE_URL='postgresql://…' \
  APPVIEW_BASE_URL=http://127.0.0.1:8081 \
  GATEWAY_APPVIEW_INTERNAL_SECRET=local-development-only swift run Gateway

# Terminal 3: Charybdis (optional; connects to live public ingestion by default)
cd services/appview-worker
APP_ENV=dev DATABASE_URL='postgresql://…' ENABLE_THIN_APPVIEW=true \
  swift run AppViewWorker
```

Use the same disposable database for these three processes. Do not point local runs at hosted Development or Production data. Charybdis consumes external Jetstream traffic unless you explicitly configure an isolated source, so start it only when that effect is intended.

## Bruno collections

- `services/gateway/bruno/` — public Gateway, XRPC, compatibility, mutation, health, and metadata requests
- `services/appview/bruno/` — direct AppView XRPC and compatibility routes
- `services/appview-worker/bruno/` — post-ingestion verification notes; the worker has no HTTP API

## Verification

| CI job | Packages |
|--------|----------|
| `redis` | `packages/swift/SocialWireRedis` with Redis integration service |
| `gateway` | `packages/swift/GatewayCore`, `services/gateway` |
| `appview` | `services/appview` |
| `charybdis` | `packages/swift/ThinAppViewCore`, `services/appview-worker` |
| `operations` | `packages/swift/OperationsCore`, `services/operations` |
| `spec` | OpenAPI contract/drift tests |

Related: [[Thin-AppView]], [[Operations]], [[Deployment-and-environments]], [[Web-app]], [[Apple-client]].
