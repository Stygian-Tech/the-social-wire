# Database migration test plan

**Location:** `database/`
**Automation:** GitHub Actions applies the migrator image to an empty disposable PostgreSQL database twice; Railway applies the same image per environment.

## Commands

```bash
# Apply all migrations to a disposable Postgres database
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

## What to validate

Run the migration script against a disposable Postgres database before merging. CI performs the same empty-database and idempotence checks, then verifies the Jetstream V2 drain indexes against representative copies of the combined claim-query shapes. Source-contract tests guard their critical predicates. This catches broken migrations and planner drift before Railway's migration service runs.

## Application tables

When `ENABLE_THIN_APPVIEW=true`, migrations define:

- `content_items` — data-minimized standard.site rows and parsed RSS content rows
- `read_marks` — derived unread state for server-side filtering
- `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` — stale-first bootstrap slices
- `pds_repo_record_cache` — short TTL record cache for sync routes
- `appview_*` — publication scopes, aggregate feeds, unread counters, ingestion/recovery, and historical Tap parity state
- `operations_*` — operator health, alerts, commands, events, audits, metrics, and traces
- `rss_feed_fetch_metadata` — Skyreader RSS polling state

See [docs/architecture/appview.md](../architecture/appview.md).

## Hosted databases

GitHub Actions does not connect to or mutate hosted databases. Railway's dedicated Database Migrator service applies the checked-in migration history to the environment's private Postgres service before dependent services deploy.

## Manual verification

- [ ] `scripts/apply-database-migrations.sh` succeeds from an empty database, is idempotent, and serializes concurrent runners with an advisory lock
- [ ] Gateway, AppView, Ingress Controller, Projection Pool, Coordinator, and Operations connect through private `DATABASE_URL` references when `APP_ENV=dev|prod`
- [ ] Ingress checkpoints advance and Projection Pool writes `content_items` after firehose connect

## Related

- [database/README.md](../../database/README.md)
- [Thin AppView architecture](../architecture/appview.md)
