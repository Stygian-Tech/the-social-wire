# Database migration test plan

**Location:** `database/`
**Automation:** explicit local or platform migration step; not GitHub Actions

## Commands

```bash
# Apply all migrations to a disposable Postgres database
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

## What to validate

Run the migration script against a disposable Postgres database before merging. This is **not** SQL unit testing; it catches broken migrations before Railway's pre-deploy migration step.

## Application tables

When `ENABLE_THIN_APPVIEW=true`, migrations define:

- `content_items` — data-minimized standard.site rows and parsed RSS content rows
- `read_marks` — derived unread state for server-side filtering
- `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` — stale-first bootstrap slices
- `pds_repo_record_cache` — short TTL record cache for sync routes
- `appview_*` — publication scopes, aggregate feeds, unread counters, ingestion/recovery, and Tap parity state
- `operations_*` — operator health, alerts, commands, events, audits, metrics, and traces
- `rss_feed_fetch_metadata` — Skyreader RSS polling state

See [docs/architecture/appview.md](../architecture/appview.md).

## Hosted databases

GitHub Actions does not connect to or mutate hosted databases. Gateway's Railway pre-deploy command applies the checked-in migration history to the environment's private Postgres service.

## Manual verification

- [ ] `scripts/apply-database-migrations.sh` succeeds from an empty database and is idempotent
- [ ] Gateway, AppView, Charybdis, and Operations connect through private `DATABASE_URL` references when `APP_ENV=dev|prod`
- [ ] Charybdis ingests into `content_items` after firehose connect

## Related

- [database/README.md](../../database/README.md)
- [Thin AppView architecture](../architecture/appview.md)
