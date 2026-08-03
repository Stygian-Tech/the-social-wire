# Supabase

Postgres migrations for the Social Wire gateway cache, AppView/Charybdis projections, Operations control plane, and Tap/recovery telemetry.

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli)
- Docker (for `supabase start`)

## Local migration validation

```bash
# From repo root
supabase start
supabase db reset --local
```

Migrations live in `migrations/`. Each file is applied in timestamp order.

## Environment

Set `SUPABASE_DATABASE_URL` independently on **gateway**, **appview**, **appview-worker**, and **operations** in hosted environments.

Gateway, AppView, and Charybdis use SQLite under `APP_ENV=local`; the Operations service requires `APP_ENV=dev|prod` plus Postgres. The local Supabase stack above validates migrations and can provide a development Postgres URL, but it is not selected automatically by `APP_ENV=local`.

Use the **session pooler** connection string on Fly and GitHub Actions (not direct `db.*.supabase.co`).

## Key tables

| Table | Used by |
|-------|---------|
| `pds_repo_record_cache` | Gateway `/v1/pds/cache/record` |
| `content_items` | Thin AppView entry index |
| `read_marks` | Server-side unread filtering |
| `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` | Stale-first bootstrap projection slices |
| `appview_publication_scopes`, `appview_unread_counters`, `appview_viewer_feeds`, `appview_feed_publications` | Materialized scope, unread, and aggregate-feed state |
| `appview_ingestion_*`, `appview_backfill_jobs`, `appview_recovery_failures`, `appview_projection_repair_outbox` | Ingestion checkpoints, gaps, recovery, and repair |
| `appview_tap_*` | Tap registrations, receipts, repository state, and parity discrepancies |
| `rss_feed_fetch_metadata` | Skyreader RSS polling metadata |
| `operations_*` | Operator state, alerts, commands, events, audits, metrics, and traces |

## CI

- **`supabase-validate`** — `supabase db reset --local` when `supabase/**` changes
- **`supabase-push-dev/prod`** — applies migrations on push to `dev` / `main`

Use the **session pooler** connection string in GitHub Actions, not direct `db.*.supabase.co`.

## Related

- [Supabase test plan](../docs/test-plans/supabase.md)
- [Thin AppView architecture](../docs/architecture/appview.md)
