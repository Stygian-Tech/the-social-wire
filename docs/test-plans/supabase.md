# Supabase test plan

**Location:** `supabase/`  
**CI:** `supabase-validate`, `supabase-push-dev`, `supabase-push-prod`

## Commands

```bash
# Start local stack (Docker required)
supabase start

# Apply all migrations to a fresh local DB
supabase db reset --local

# Validate configured development connection secrets (dry run)
bash scripts/supabase-verify-connection.sh dev
```

## What CI validates

The `supabase-validate` job runs `supabase db start` and `supabase db reset --local` to ensure migrations apply cleanly. This is **not** SQL unit testing — it catches broken migrations before push.

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

## CI push (dev/prod)

Push to `dev` or `main` triggers `scripts/supabase-ci-push.sh` when `supabase/**` changes. GitHub Actions must use the **session pooler** `DATABASE_URL`, not direct `db.*.supabase.co`.

## Manual verification

- [ ] `supabase db reset --local` succeeds after adding a migration
- [ ] Gateway, AppView, Charybdis, and Operations connect with their own `SUPABASE_DATABASE_URL` when `APP_ENV=dev|prod`
- [ ] Charybdis ingests into `content_items` after firehose connect

## Related

- [supabase/README.md](../../supabase/README.md)
- [Thin AppView architecture](../architecture/appview.md)
