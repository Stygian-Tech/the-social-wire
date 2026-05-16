# Social Wire API

Swift/Hummingbird gateway that complements the Next.js web app: publishes OAuth client-metadata for every platform caller, verifies ATProto bearer tokens + DPoP proofs, and fronts short-lived `repo.getRecord` accelerators keyed by DID.

## What this service does

- **OAuth surface**: exposes `GET /oauth/client-metadata.json` (SPA/Tunnel) alongside `GET /ios-client-metadata.json`; scope literals come from **`ATProtoOAuthScopes`** so Swift + Next.js stay aligned (`apps/web/public/client-metadata.json` remains the authoring reference).
- **Authenticated sync lanes**: forwards `Authorization` + **`DPoP`** headers verbatim to ATProto repos for `GET /v1/sync/preferences` and selective `GET /v1/pds/cache/record?collection=&rkey=` reads (short TTL SQLite/Supabase cache via `pds_repo_record_cache`).
- **Legacy reader APIs (migration only)**: follow-graph discovery (`DiscoveryService`) plus publication entry surfaces (`ContentService`) compile in-tree yet register **only** when `ENABLE_LEGACY_CONTENT_API=true` for phased cutovers without deleting code paths prematurely.

LATRHTTPS merge APIs deliberately stay elsewhere—consume those flows through the deployed web stack.

See [`packages/lexicons/`](../../packages/lexicons/README.md) for record shapes that originate on users’ own PDSes.

## Prerequisites

- Swift 6+
- Docker (optional local compose)
- Supabase Postgres project — **required for `APP_ENV=dev|prod`**; local mode persists to SQLite (`APP_ENV=local`)

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP_ENV` | | `local` | `local` \| `dev` \| `prod` — chooses SQLite vs Postgres |
| `SQLITE_DB_PATH` | | `./social-wire.sqlite` | SQLite backing file (`APP_ENV=local`) |
| `SUPABASE_DATABASE_URL` | ✅ (dev/prod) | — | Postgres connection URI for Supabase workloads |
| `ENABLE_LEGACY_CONTENT_API` | | `false` | When truthy (`1`, `true`, `yes`, `on`; case insensitive), mounts `/discovery/**`, `/publications/**`, `/entries/**` |
| `PORT` | | `8080` | Listening port (`--port` overrides) |
| `BIND_HOST` | | `0.0.0.0` | Listen address (`--hostname` overrides) |
| `DOTENV_PATH` | | `.env` | Optional dotenv file relative to cwd |
| `ATPROTO_PLC_URL` | | `https://plc.directory` | PLC directory base |
| `OAUTH_PUBLIC_ORIGIN` | | — | Overrides forwarded authority when serving OAuth metadata |

`SQLITE_DB_PATH` and `SUPABASE_DATABASE_URL` toggle automatically through `APP_ENV`.

### Dotenv (`.env`)

Process + container env beats file values:

```bash
cd services/api
cp .env.example .env
APP_ENV=local swift run App
```

## Local development

```bash
# Compose (infra/docker binds Caddy locally)
cp infra/docker/.env.example infra/docker/.env
cd infra/docker && docker compose up

# Native Swift runner
cd services/api
APP_ENV=local swift run App
```

- Direct HTTP: [`http://127.0.0.1:8080`](http://127.0.0.1:8080)
- Routed TLS: [`https://api.localhost`](https://api.localhost)

### OAuth client metadata

`GET /oauth/client-metadata.json` mirrors the SPA JSON but uses the **`/oauth/...`** slug so tunnels can host parallel documents. Native metadata remains at **`/ios-client-metadata.json`**.

**Origin resolution:** honours `OAUTH_PUBLIC_ORIGIN` first, then `X-Forwarded-Proto` + `:authority` (or inferred `http` for loopback interfaces).

Example:

```bash
curl -sS http://127.0.0.1:8080/oauth/client-metadata.json | jq .
```

### Bruno requests

[`bruno`](https://www.usebruno.com/) workspace under [`services/api/bruno`](./bruno):

1. Import the folder as a Bruno collection (`bruno.json` present).
2. Pick `local` / `dev` / `prod` environments.
3. Populate `oauthAccessToken` **and** `dpopProof` from your OAuth session whenever hitting `/v1/*` routes.
4. Legacy examples call out the `ENABLE_LEGACY_CONTENT_API=true` prerequisite in file names/comments.

Never commit bearer material—use Bruno secret variables locally.

## Running tests / coverage

Default CI runs on GitHub Actions (`test-api` job) with `swift test --enable-code-coverage` followed by **`llvm-cov export`** uploads tagged `codecov` **`api`**.

Locally:

```bash
cd services/api
swift test --enable-code-coverage
PROF=$(find .build -path '**/codecov/default.profdata' | head -n 1)
BIN=$(find .build -type f -perm -111 -name SocialWireAPIPackageTests | grep -v dSYM | head -n 1)
llvm-cov export -format=lcov -instr-profile="$PROF" "$BIN" > coverage.lcov
```

## Supabase schema

Operational migrations live beside infrastructure sources:

- Legacy cache tables originate from the hosted Supabase project’s older migrations (`discovery_cache`, `entry_cache`).
- Repo checkout includes [`infra/supabase/migrations/20260516144500_add_pds_repo_record_cache.sql`](../infra/supabase/migrations/20260516144500_add_pds_repo_record_cache.sql) for **`pds_repo_record_cache`**. Apply via Supabase MCP / CLI before pointing `SUPABASE_DATABASE_URL` at refreshed environments.

## API reference / HTTP contract

Canonical description: [`packages/spec/openapi.yaml`](../../packages/spec/openapi.yaml).

| Method | Path | Notes |
|--------|------|-------|
| `GET` | `/health` | Liveness probe — no auth |
| `GET` | `/oauth/client-metadata.json` | Web OAuth metadata (`application_type=web`), CORS `*` |
| `GET` | `/ios-client-metadata.json` | Native ATS metadata (`application_type=native`) |
| `GET` | `/v1/sync/preferences` | Requires bearer + **`DPoP`** headers + valid ATProto JWT |
| `GET` | `/v1/pds/cache/record` | Generic repo record accel (`collection`,`rkey` query params) |
| `POST` | `/discovery/refresh` | **`ENABLE_LEGACY_CONTENT_API`** |
| `GET` | `/discovery/{userDid}` | Legacy gated |
| `GET` | `/publications/{pubId}/entries` | Legacy gated |
| `GET` | `/entries/{entryId}` | Legacy gated |

**Authentication:** JWT in `Authorization: Bearer <jwt>` **`or`** `Authorization: DPoP <jwt>` prefix (token payload identical) plus **mandatory** `DPoP: <proof>` verifying SHA-256 `ath` hashes of the bearer string and optional `cnf.jkt`.

## Architecture (conceptual)

```
Clients (SPA / ATS)
   │ OAuth discovery (public)
   ▼
Hummingbird router
 ├── OAuthMetadataRoutes (/oauth/client-metadata.json, /ios-client-metadata.json)
 ├── ATProtoAuthMiddleware (JWKS verified JWT + DPoP)
 │    └── PreferenceSyncService + SyncRoutes
 └── (optional legacy) DiscoveryService + ContentService
          ▼                    ▼
     CacheStore ───────► Supabase/SQLite
```

## Docker

Build a local tag:

```bash
docker build -t social-wire-api:local services/api/
```

## Deployment & container registry

[`deploy.yml`](../../.github/workflows/deploy.yml):

- Depot still builds Docker layers for speed **but publishes to GHCR** using `GITHUB_TOKEN`.
- Canonical image refs look like **`ghcr.io/<org-or-user>/<repository>/social-wire-api:<branch-tag|sha>`** (GitHub forces lowercase URIs).

**AWS App Runner:** swap the hosted image URI to GHCR + attach repository credentials scoped to **`read:packages`** (typically a PAT or shared deploy bot). Older Docker Hub sources can be deprecated once workloads pull GHCR exclusively.
