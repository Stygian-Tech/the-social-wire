# Social Wire — Thin AppView Worker

Jetstream firehose ingestion and TTL cleanup for the GDPR-safe Level-1 read index (`content_items`, `read_marks`).

Shared persistence and indexing live in **`packages/swift/ThinAppViewCore`**. The HTTP API in **`services/api`** reads from the same stores but does not run ingestion.

## Run locally

```bash
cd services/worker
cp .env.example .env
APP_ENV=local ENABLE_THIN_APPVIEW=true swift run Worker
```

## Deploy

From **`services/worker`** (Fly uses the monorepo root as Docker build context for `packages/`):

```bash
cd services/worker
bash deploy.sh dev    # or main
```

Or explicitly:

```bash
cd services/worker
fly deploy ../.. --config services/worker/fly.toml --app the-social-wire-dev-worker
```

From repo root, CI uses `bash scripts/fly-deploy-worker.sh dev`.

Configs: `fly.toml` (dev), `fly.prod.toml` (prod).

## Bruno requests

The worker exposes **no HTTP routes**. Import [`bruno/`](./bruno) in [Bruno](https://www.usebruno.com/) to verify ingestion through the API (`/v1/appview/*` on `api.*.thesocialwire.app`). See [`services/api/bruno`](../api/bruno) for the full API surface.

## Environment

Same database variables as the API (`APP_ENV`, `SUPABASE_DATABASE_URL`, `SQLITE_DB_PATH`) plus Thin AppView flags (`ENABLE_THIN_APPVIEW`, relay URL, TTLs). See `.env.example`.

## Testing

```bash
cd services/worker
swift test
```

Also run `packages/swift/ThinAppViewCore` tests — see [docs/test-plans/worker.md](../../docs/test-plans/worker.md).

## Architecture

The worker executable calls `ThinAppViewWorkerRuntime` from **ThinAppViewCore**. Ingestion connects to the configured Jetstream relay; TTL cleanup runs on a schedule. No HTTP server — verify output via API `/v1/appview/*` routes or Bruno.

## Related

- [ThinAppViewCore README](../../packages/swift/ThinAppViewCore/README.md)
- [Thin AppView architecture](../../docs/architecture/appview.md)
