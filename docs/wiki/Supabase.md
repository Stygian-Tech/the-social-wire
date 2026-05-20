# Supabase

Postgres migrations and local CLI for the gateway cache and Thin AppView index.

**Runbook:** [supabase/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/supabase/README.md)  
**Test plan:** [docs/test-plans/supabase.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/supabase.md)

## Local development

```bash
supabase start
supabase db reset --local
```

Requires Docker. Migrations live in `supabase/migrations/`.

## Key tables

| Table | Purpose |
|-------|---------|
| `pds_repo_record_cache` | Short TTL cache for `/v1/pds/cache/record` |
| `content_items` | Thin AppView Level-1 entry index |
| `read_marks` | Derived read state for server-side unread filtering |

## CI

- **`supabase-validate`** — `db reset --local` on PR/push when `supabase/**` changes
- **`supabase-push-dev/prod`** — applies migrations on push to `dev` / `main`

GitHub Actions must use the **session pooler** `DATABASE_URL`, not direct `db.*.supabase.co`.

## Related

- [[Thin-AppView]]
- [[Service-API]]
- [[Testing]]
