# Supabase test plan

**Location:** `supabase/`  
**CI:** `supabase-validate`, `supabase-push-dev`, `supabase-push-prod`

## Commands

```bash
# Start local stack (Docker required)
supabase start

# Apply all migrations to a fresh local DB
supabase db reset --local

# Validate connection string (CI helper)
./scripts/supabase-verify-connection.sh "$DATABASE_URL"
```

## What CI validates

The `supabase-validate` job runs `supabase db start` and `supabase db reset --local` to ensure migrations apply cleanly. This is **not** SQL unit testing — it catches broken migrations before push.

## Thin AppView tables

When `ENABLE_THIN_APPVIEW=true`, migrations define:

- `content_items` — Level-1 entry index rows
- `read_marks` — derived unread state for server-side filtering
- `sidebar_projection_cache` — stale-first sidebar/unread/first-page snapshots
- `pds_repo_record_cache` — short TTL record cache for sync routes

See [docs/architecture/appview.md](../architecture/appview.md).

## CI push (dev/prod)

Push to `dev` or `main` triggers `scripts/supabase-ci-push.sh` when `supabase/**` changes. GitHub Actions must use the **session pooler** `DATABASE_URL`, not direct `db.*.supabase.co`.

## Manual verification

- [ ] `supabase db reset --local` succeeds after adding a migration
- [ ] API connects with `SUPABASE_DATABASE_URL` when `APP_ENV=dev|prod` on gateway, appview, and appview-worker
- [ ] AppView worker ingests into `content_items` after firehose connect

## Related

- [supabase/README.md](../../supabase/README.md)
- [Thin AppView architecture](../architecture/appview.md)
