# Social Wire API

Swift/Hummingbird gateway that complements the Next.js web app: publishes OAuth client-metadata for every platform caller, verifies ATProto bearer tokens + DPoP proofs, and fronts short-lived `repo.getRecord` accelerators keyed by DID.

## What this service does

- **OAuth surface**: exposes `GET /oauth/client-metadata.json` (SPA/Tunnel) alongside `GET /ios-client-metadata.json`; scope literals come from **`ATProtoOAuthScopes`** so Swift + Next.js stay aligned (`apps/web/public/client-metadata.json` remains the authoring reference).
- **Authenticated sync lanes**: forwards `Authorization` + **`DPoP`** headers verbatim to ATProto repos for `GET /v1/sync/preferences` and selective `GET /v1/pds/cache/record?collection=&rkey=` reads (short TTL SQLite/Supabase cache via `pds_repo_record_cache`).
- **Thin AppView (optional)**: when **`ENABLE_THIN_APPVIEW=true`**, mounts **`/v1/appview/*`** for Level-1 entry timelines, read-mark write-through, enrollment backfill, and privacy purge; a separate **`App worker`** Fly process ingests Jetstream commits into **`content_items`** / **`read_marks`** (EU **`ams`**).
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
| `ENABLE_THIN_APPVIEW` | | `false` | When truthy, mounts `/v1/appview/*` and bootstraps `ThinAppViewStore` |
| `THIN_APPVIEW_RELAY_WS_URL` | | Jetstream default (filtered collections) | WebSocket URL for worker firehose subscriber |
| `THIN_APPVIEW_CONTENT_TTL_SECONDS` | | `2592000` (30 days) | `content_items.expires_at` horizon |
| `THIN_APPVIEW_READ_MARK_TTL_SECONDS` | | `15552000` (180 days) | `read_marks` retention window |
| `THIN_APPVIEW_MAX_ENROLL_AUTHORS` | | `500` | Max DIDs per `POST /v1/appview/enroll` |
| `PORT` | | `8080` | Listening port (`--port` overrides) |
| `BIND_HOST` | | `0.0.0.0` | Listen address (`--hostname` overrides) |
| `DOTENV_PATH` | | `.env` | Optional dotenv file relative to cwd |
| `ATPROTO_PLC_URL` | | `https://plc.directory` | PLC directory base |
| `OAUTH_PUBLIC_ORIGIN` | | — | Overrides forwarded authority when serving OAuth metadata |
| `OAUTH_GATEWAY_ALLOWED_CLIENT_IDS` | | _(empty)_ | Comma/whitespace-separated **`client_id`** / **`azp`** values permitted to call **`ATProtoAuthMiddleware`–protected** `/v1/*` routes on this deploy (first-party web + native URLs) |
| `OAUTH_GATEWAY_ALLOWED_AUDIENCES` | | _(empty)_ | Comma/whitespace-separated JWT **`aud`** strings accepted for the same routes (RFC 8707–style resource identifiers, e.g. `https://api.thesocialwire.app`) |
| `OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT` | | `false` | When `1`/`true`/`yes`/`on`, require the access token to satisfy at least one nonempty allowlist (**`OAUTH_GATEWAY_ALLOWED_CLIENT_IDS`** or **`OAUTH_GATEWAY_ALLOWED_AUDIENCES`**). Local dev should keep this off until you inspect real issuer claims. |

**Self-hosting:** Operators who run their own gateway set their own allowlists (or leave enforcement off on private networks). Upstream Social Wire hosted environments are expected to enable known-client checks once claims are confirmed.

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

# Optional: Thin AppView worker (ingestion + TTL cleanup)
APP_ENV=local ENABLE_THIN_APPVIEW=true swift run App worker
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

## Running tests

CI runs `swift test` in the `test-api` job (`.github/workflows/ci.yml`). The package builds **App** and **AppTests** with **`-warnings-as-errors`**, so any compiler warning in those targets fails the build.

Locally:

```bash
cd services/api
swift test
```

For optional local coverage and `llvm-cov` / `lcov` export, run `swift test --enable-code-coverage` and use the Swift toolchain’s `llvm-profdata` / `llvm-cov` against the `SocialWireAPIPackageTests` binary under `.build` (paths differ by platform).

## Supabase schema

Operational migrations live at the repo root for the **Supabase CLI** (and optionally the dashboard’s GitHub integration):

- Legacy cache tables originate from the hosted Supabase project’s older migrations (`discovery_cache`, `entry_cache`).
- [`supabase/migrations/20260516144500_add_pds_repo_record_cache.sql`](../../supabase/migrations/20260516144500_add_pds_repo_record_cache.sql) adds **`pds_repo_record_cache`**.
- [`supabase/migrations/20260519120000_add_thin_appview.sql`](../../supabase/migrations/20260519120000_add_thin_appview.sql) adds **`content_items`** and **`read_marks`** for the Thin AppView index.

Apply from the **`dev`** / **`main`** branches via [`.github/workflows/supabase.yml`](../../.github/workflows/supabase.yml) (**`supabase link`** + **`supabase db push`**), or locally with the same commands after **`supabase link`**, before pointing **`SUPABASE_DATABASE_URL`** at refreshed environments.

**GitHub Actions secrets** (repository → *Settings* → *Secrets and variables* → *Actions*):

| Secret | Used on | Purpose |
|--------|---------|---------|
| `SUPABASE_ACCESS_TOKEN` | `dev`, `main` | [CLI access token](https://supabase.com/dashboard/account/tokens) for `supabase link` / `db push` |
| `SUPABASE_DEV_PROJECT_REF` | `dev` pushes | Project ref (**Settings → General** in the Supabase dashboard) |
| `SUPABASE_DEV_DATABASE_URL` | `dev` pushes (preferred) | **Session pooler** URI from **Connect** (port **5432**), e.g. `postgresql://postgres.[ref]:[password]@…pooler…:5432/postgres` |
| `SUPABASE_DEV_DB_PASSWORD` | `dev` pushes (fallback) | Database password only — must match **Project Settings → Database** for the same ref |
| `SUPABASE_PROD_PROJECT_REF` | `main` pushes | Production project ref |
| `SUPABASE_PROD_DATABASE_URL` | `main` pushes (preferred) | Session pooler URI (same format as dev) |
| `SUPABASE_PROD_DB_PASSWORD` | `main` pushes (fallback) | Production database password |

If you use a **single** hosted project for both branches, set the same ref/password in the **DEV** and **PROD** secrets. If the dashboard is also set to auto-apply the same `supabase/migrations/` tree, disable one path so migrations are not applied twice.

**Workflow wiring:** pushes to **`dev`** read **`SUPABASE_DEV_PROJECT_REF`** plus **`SUPABASE_DEV_DATABASE_URL`** (preferred) or **`SUPABASE_DEV_DB_PASSWORD`**; pushes to **`main`** use the **`SUPABASE_PROD_*`** pair. CI runs [`.github/workflows/supabase.yml`](../../.github/workflows/supabase.yml) via [`scripts/supabase-ci-push.sh`](../../scripts/supabase-ci-push.sh) (Supabase CLI **2.100.1** pinned).

**Troubleshooting `password authentication failed` (SQLSTATE 28P01):**

1. In Supabase **Project Settings → Database**, confirm the password or **reset** it.
2. Update the matching GitHub secret (`SUPABASE_DEV_DB_PASSWORD` or `SUPABASE_PROD_DB_PASSWORD`) with the **plain password** (not a `postgres://` URI).
3. Prefer adding **`SUPABASE_DEV_DATABASE_URL`** / **`SUPABASE_PROD_DATABASE_URL`**: copy the **Session pooler** connection string from **Connect** (port **5432**). This avoids pooler auth quirks with `--password` on the CLI.
4. Ensure the ref secret matches the project whose password you copied (dev vs prod).

**Troubleshooting `network is unreachable` / IPv6 dial errors:**

The secret is almost certainly a **direct** URI (`db.[ref].supabase.co`). GitHub Actions cannot reach that host over IPv6. Replace it with the **Session pooler** URI from **Connect** (host like `…pooler.supabase.com`, user `postgres.[ref]`, port **5432**). CI skips direct `DATABASE_URL` values when `SUPABASE_*_DB_PASSWORD` is also set and falls back to `supabase link` + password.

CI uses the pooler because GitHub Actions typically cannot reach Supabase **direct** DB endpoints over **IPv6**.

## API reference / HTTP contract

Canonical description: [`packages/spec/openapi.yaml`](../../packages/spec/openapi.yaml).

| Method | Path | Notes |
|--------|------|-------|
| `GET` | `/health` | Liveness probe — no auth |
| `GET` | `/oauth/client-metadata.json` | Web OAuth metadata (`application_type=web`), CORS `*` |
| `GET` | `/ios-client-metadata.json` | Native ATS metadata (`application_type=native`) |
| `GET` | `/v1/sync/preferences` | Requires bearer + **`DPoP`** headers + valid ATProto JWT |
| `GET` | `/v1/pds/cache/record` | Generic repo record accel (`collection`,`rkey` query params) |
| `GET` | `/v1/appview/entries` | **`ENABLE_THIN_APPVIEW`** — Level-1 entry timeline + unread filter |
| `POST` | `/v1/appview/read-marks` | Write-through read mark after PDS upsert |
| `DELETE` | `/v1/appview/read-marks` | Write-through unread (delete mark) |
| `POST` | `/v1/appview/enroll` | Backfill followed author DIDs into index |
| `DELETE` | `/v1/appview/privacy/purge` | Delete viewer read marks from index |
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
 │    ├── PreferenceSyncService + SyncRoutes
 │    └── (optional) ThinAppViewRoutes + worker firehose ingest
 └── (optional legacy) DiscoveryService + ContentService
          ▼                    ▼
     CacheStore / ThinAppViewStore ──► Supabase/SQLite (ams)
```

Deploy the ingestion worker as a separate Fly process when **`ENABLE_THIN_APPVIEW`** is on:

```bash
# From repo root
fly deploy ./services/api --config services/api/fly.worker.toml
```

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## Docker

Build a local tag:

```bash
docker build -t social-wire-api:local services/api/
```

## Deployment (Fly.io)

[`deploy.yml`](../../.github/workflows/deploy.yml) runs on pushes to **`main`** and **`dev`**: `flyctl deploy ./services/api --remote-only` from the **repo root**, so the [build context](https://fly.io/docs/launch/monorepo/) is this package directory and [`fly.toml`](fly.toml) / `Dockerfile` resolve correctly.

**Native Fly ↔ GitHub deploy:** Fly usually clones the repo and runs deploy from the **repository root**, so it looks for **`./fly.toml` at root** unless you set a **subdirectory / root directory** for the app in the Fly dashboard (name varies by UI) to **`services/api`**, or use this workflow instead of the hosted GitHub deploy.

**GitHub Actions secrets**

| Secret | Purpose |
|--------|---------|
| `FLY_API_TOKEN` | Deploy token from [Fly access tokens](https://fly.io/docs/flyctl/auth-token/) |
| `FLY_APP_PROD` | Fly app name for `main` (e.g. `social-wire-api`) |
| `FLY_APP_DEV` | Fly app name for `dev` (e.g. `social-wire-api-dev`) |

Create both apps in your Fly org (`fly apps create …`), then set **`SUPABASE_DATABASE_URL`**, **`APP_ENV`** (`prod` / `dev`), and any other runtime vars with `fly secrets set` (or the dashboard). **`OAUTH_PUBLIC_ORIGIN`** should match the HTTPS URL clients use for OAuth metadata when it differs from the default Fly hostname.

Local smoke: from the **repository root**, `fly deploy ./services/api` (or `cd services/api && fly deploy`); or use **`infra/docker`** compose, which builds this Dockerfile instead of pulling a registry image.
