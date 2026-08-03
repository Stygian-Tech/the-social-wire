# Database

Provider-neutral Postgres migrations for gateway/AppView data, ingestion recovery, Tap parity, and Operations state.

**Runbook:** [database/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/database/README.md)
**Test plan:** [docs/test-plans/database.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/database.md)

## Local migration validation

```bash
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

Migrations live in `database/migrations/`. Gateway, AppView, and Charybdis use SQLite when `APP_ENV=local`; Operations requires a development or production Postgres URL.

## Key tables

| Table | Purpose |
|-------|---------|
| `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` | Stale-first bootstrap slices |
| `pds_repo_record_cache` | Short TTL cache for `/v1/pds/cache/record` |
| `content_items` | Thin AppView standard.site and RSS entry index |
| `read_marks` | Derived read state for server-side unread filtering |
| `appview_*` | Materialized scopes/feeds/unread state plus ingestion, repair, recovery, and Tap parity |
| `operations_*` | Operations health, alerts, commands, audit, events, metrics, and traces |
| `rss_feed_fetch_metadata` | Skyreader RSS poll state |

## Automation

GitHub Actions does not mutate hosted databases. Gateway's Railway pre-deploy command applies the migration history; validate it locally against a disposable Postgres database.

## Related

- [[Thin-AppView]]
- [[Service-API]]
- [[Testing]]
