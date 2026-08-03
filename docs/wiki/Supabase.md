# Supabase

Postgres migrations and local CLI for gateway/AppView data, ingestion recovery, Tap parity, and Operations state.

**Runbook:** [supabase/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/supabase/README.md)  
**Test plan:** [docs/test-plans/supabase.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/supabase.md)

## Local migration validation

```bash
supabase start
supabase db reset --local
```

Requires Docker. Migrations live in `supabase/migrations/`. Gateway, AppView, and Charybdis use SQLite when `APP_ENV=local`; Operations requires a development or production Postgres URL.

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

## CI

- **`supabase-validate`** — `db reset --local` on PR/push when `supabase/**` changes
- **`supabase-push-prod`** — applies migrations to production on push to `main`

Development uses Railway Postgres and the same checked-in migration history. CI no longer writes to
the retired Supabase Dev project.

GitHub Actions must use the **session pooler** `DATABASE_URL`, not direct `db.*.supabase.co`.

## Related

- [[Thin-AppView]]
- [[Service-API]]
- [[Testing]]
