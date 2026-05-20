# Supabase

Postgres migrations for the Social Wire gateway — record cache and Thin AppView index.

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli)
- Docker (for `supabase start`)

## Local development

```bash
# From repo root
supabase start
supabase db reset --local
```

Migrations live in `migrations/`. Each file is applied in timestamp order.

## Environment

Set `SUPABASE_DATABASE_URL` in `services/api/.env` and `services/worker/.env` when `APP_ENV=dev|prod`.

Local mode (`APP_ENV=local`) uses SQLite instead — Supabase is optional for gateway-only dev.

## Key tables

| Table | Used by |
|-------|---------|
| `pds_repo_record_cache` | `/v1/pds/cache/record` |
| `content_items` | Thin AppView entry index |
| `read_marks` | Server-side unread filtering |

## CI

- **`supabase-validate`** — `supabase db reset --local` when `supabase/**` changes
- **`supabase-push-dev/prod`** — applies migrations on push to `dev` / `main`

Use the **session pooler** connection string in GitHub Actions, not direct `db.*.supabase.co`.

## Related

- [Supabase test plan](../docs/test-plans/supabase.md)
- [API README](../services/api/README.md) — secrets troubleshooting
