# Database migrations

Provider-neutral Postgres migrations for durable/rebuildable AppView and Charybdis state, the Operations control plane, Tap/recovery telemetry, and temporary cache rollback tables. Railway Postgres is the canonical hosted durable database; Redis cache data is disposable.

## Prerequisites

- PostgreSQL client tools (`psql`)

## Apply migrations

```bash
# From repo root, against a disposable database
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

Migrations live in `migrations/`. The runner applies each file once in timestamp order and records versions in `public.schema_migrations`.

## Environment

Set `DATABASE_URL=${{Postgres.DATABASE_URL}}` independently on **gateway**, **appview**, **appview-worker**, and **operations** in Railway.

Gateway, AppView, and Charybdis contain SQLite backends, but their current
process entry points share the Operations environment guard and reject
`APP_ENV=local`. Runnable local service integration therefore uses `APP_ENV=dev`
with an isolated disposable Postgres `DATABASE_URL`. Railway services use the
private `DATABASE_URL`, not `DATABASE_PUBLIC_URL`.

## Key tables

| Table | Used by |
|-------|---------|
| `pds_repo_record_cache` | Active Gateway cache when an environment selects Postgres; rollback target in Redis mode |
| `content_items` | Thin AppView entry index |
| `read_marks` | Server-side unread filtering |
| `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` | Active projection caches in Postgres mode; rollback targets in Redis mode |
| `appview_publication_scopes`, `appview_unread_counters`, `appview_viewer_feeds`, `appview_feed_publications` | Materialized scope, unread, and aggregate-feed state |
| `appview_ingestion_*`, `appview_backfill_jobs`, `appview_recovery_failures`, `appview_projection_repair_outbox` | Ingestion checkpoints, gaps, recovery, and repair |
| `appview_tap_*` | Tap registrations, receipts, repository state, and parity discrepancies |
| `rss_feed_fetch_metadata` | Skyreader RSS polling metadata |
| `operations_*` | Operator state, alerts, commands, events, audits, metrics, and traces |

## Automation

GitHub Actions does not mutate hosted databases. The Gateway Railway deployment runs the checked-in migration runner as its pre-deploy command. Validate migration changes against a disposable Postgres database before merging.

## Related

- [Database test plan](../docs/test-plans/database.md)
- [Thin AppView architecture](../docs/architecture/appview.md)
- [Redis ownership and rollback](../docs/architecture/redis.md)
