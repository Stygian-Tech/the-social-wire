# Social Wire API

Swift/Hummingbird service that handles publication discovery and content retrieval for The Social Wire.

## What this service does

- **Discovery**: scans a user's ATProto follow graph and finds standard.site publications via a three-step chain (lexicon-native → profile heuristic → directory fallback)
- **Content**: fetches paginated entry lists and entry detail from ATProto repos and standard.site feeds; sanitizes HTML before returning
- **Cache**: stores discovery results and entry content — SQLite locally (`APP_ENV=local`) or Supabase Postgres in dev/prod (`APP_ENV=dev|prod`)

**What it does NOT do**: manage folders or subscription preferences. That data lives as ATProto records in the user's own PDS — see [`packages/lexicons/`](../../packages/lexicons/README.md).

## Prerequisites

- Swift 6.1+
- Docker (for containerized local dev)
- A running Supabase project — **only required for `APP_ENV=dev` or `prod`**; local mode uses SQLite with no external dependencies

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP_ENV` | | `local` | `local` \| `dev` \| `prod` — controls which cache backend is used |
| `SQLITE_DB_PATH` | | `./social-wire.sqlite` | Path to the SQLite file. Only used when `APP_ENV=local` |
| `SUPABASE_DATABASE_URL` | ✅ (dev/prod) | — | Postgres connection string. Required when `APP_ENV=dev` or `prod` |
| `PORT` | | `8080` | Port the server listens on |
| `ATPROTO_PLC_URL` | | `https://plc.directory` | PLC directory for DID resolution |

`SQLITE_DB_PATH` and `SUPABASE_DATABASE_URL` are mutually exclusive — the service picks one based on `APP_ENV`.

## Local development

No Supabase account required. The service uses SQLite automatically when `APP_ENV=local`.

```bash
# From the repo root
cp infra/docker/.env.example infra/docker/.env
# The default .env uses APP_ENV=local — no edits needed for local dev

# Option A: run with Docker Compose (recommended — SQLite is persisted in a named volume)
cd infra/docker
docker compose up

# Option B: run directly with Swift (SQLite file created in services/api/)
cd services/api
APP_ENV=local swift run App
```

The API will be available at:
- Direct: `http://localhost:8080`
- Via Caddy: `https://api.localhost` (trust Caddy's local CA with `caddy trust`)

## Running tests

```bash
cd services/api
swift test --enable-code-coverage
```

To view a coverage report:
```bash
# After swift test, export lcov
BINARY=$(swift build --show-bin-path)/App
llvm-cov export \
  -format="lcov" \
  -instr-profile=.build/debug/codecov/default.profdata \
  "$BINARY" > coverage.lcov

# Generate HTML report
genhtml coverage.lcov --output-directory coverage-report
open coverage-report/index.html
```

## Supabase setup

The schema is managed via Supabase MCP migrations. The initial migration (`create_cache_tables`) has already been applied to the `The Social Wire` project (`byoeubizcjiyhlvrykzb`).

To get your database URL:
1. Go to the [Supabase dashboard](https://supabase.com/dashboard/project/byoeubizcjiyhlvrykzb)
2. Settings → Database → Connection string (URI mode)
3. Copy the connection string and set it as `SUPABASE_DATABASE_URL`

## API reference

See [`packages/spec/openapi.yaml`](../../packages/spec/openapi.yaml) for the full OpenAPI 3.1 spec.

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (no auth) |
| `POST` | `/discovery/refresh` | Trigger follow graph re-scan |
| `GET` | `/discovery/{userDid}` | Get cached discovery results |
| `GET` | `/publications/{pubId}/entries` | Paginated entry list |
| `GET` | `/entries/{entryId}` | Entry detail with sanitized HTML |

**Authentication:** `Authorization: DPoP <token>` — ATProto DPoP-bound access token.

## Architecture

```
ATProto network (follows, PDS records)
        │
        ▼
DiscoveryService ──► DiscoveryChain
  Step 1: LexiconNativeDiscovery   (standard.site publication record)
  Step 2: ProfileLinkHeuristic     (standard.site URL in profile)
  Step 3: DirectoryFallback        (index API, when available)
        │
        ▼
CacheStore (protocol)
  ├── SQLiteCache   (APP_ENV=local  — GRDB, no external deps)
  └── SupabaseCache (APP_ENV=dev/prod — PostgresNIO → Supabase)
        │
        ▼
ContentService ──► HTMLSanitizer
        │
        ▼
Hummingbird routes ──► ATProtoAuthMiddleware
```

## Docker

Build:
```bash
docker build -t social-wire-api:local services/api/
```

Run locally (SQLite, no Supabase needed):
```bash
docker run -p 8080:8080 \
  -e APP_ENV=local \
  -e SQLITE_DB_PATH=/data/sqlite/social-wire.sqlite \
  -v social-wire-sqlite:/data/sqlite \
  social-wire-api:local
```

Run against Supabase (dev/prod):
```bash
docker run -p 8080:8080 \
  -e APP_ENV=dev \
  -e SUPABASE_DATABASE_URL="postgresql://postgres:PASSWORD@db.xxx.supabase.co:5432/postgres" \
  social-wire-api:local
```

## Deployment

- **Dev**: push to `dev` branch → Depot builds `:dev` tag → AWS App Runner `social-wire-api-dev` deploys
- **Prod**: push to `main` branch → Depot builds `:latest` tag → AWS App Runner `social-wire-api-prod` deploys

See [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml) for the full pipeline.
