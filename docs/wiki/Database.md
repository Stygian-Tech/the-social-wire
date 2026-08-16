# Database

Provider-neutral Postgres migrations for Gateway/AppView data, ingestion recovery, Tap parity, and Operations state. Hosted Development and Production use isolated Railway Postgres services.

**Runbook:** [database/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/database/README.md)
**Test plan:** [docs/test-plans/database.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/database.md)

## Local migration validation

```bash
DATABASE_URL='postgresql://…' bash scripts/apply-database-migrations.sh
```

Migrations live in `database/migrations/`. Validate them only against an isolated disposable database.

Gateway, AppView, and Charybdis still contain SQLite backends, but their current process entry points share the Operations environment guard and reject `APP_ENV=local`. Until that mismatch is fixed, runnable local service integration uses `APP_ENV=dev` plus an isolated Postgres `DATABASE_URL`. Do not use the hosted Development or Production database for local testing.

## Key tables

| Table | Purpose |
|-------|---------|
| `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache` | Active for Postgres cache mode; rollback target while an environment selects Redis |
| `pds_repo_record_cache` | Active for Gateway Postgres cache mode; rollback target while an environment selects Redis |
| `content_items` | Thin AppView standard.site and RSS entry index |
| `read_marks`, `appview_unread_overrides` | Explicit per-entry read/unread state |
| `appview_publication_read_floors` | Scoped bulk-read boundaries used by Mark All As Read |
| `appview_publication_scopes`, `appview_unread_counters` | Materialized publication membership and unread totals |
| `appview_viewer_feeds`, `appview_feed_publications`, `appview_publication_scope_keys` | Viewer feed membership and publication aliases |
| `appview_ingestion_*`, `appview_jetstream_endpoints` | Relay checkpoints, gaps, and recovery controls |
| `appview_tap_*`, `appview_projection_repair_outbox` | Tap registration, parity evidence, and projection repair |
| `operations_*` | Operations health, alerts, commands, audit, events, metrics, and traces |
| `rss_feed_fetch_metadata` | Skyreader RSS poll state |
| `discovery_cache`, `entry_cache` | Legacy content-path caches retained for compatibility while legacy routes are gated |

`POST /xrpc/app.thesocialwire.appview.purgeViewerData` currently removes only the authenticated
viewer’s `read_marks` and `appview_unread_overrides`. It does not remove bulk-read
floors, materialized counters, publication scopes, feed membership, or indexed
content. See [[Account-settings-and-privacy]] before describing the action as a
complete account-data deletion.

## Automation

GitHub Actions does not mutate hosted databases. Gateway's Railway pre-deploy command applies the migration history; validate it locally against a disposable Postgres database.

## Related

- [[Thin-AppView]]
- [[Service-API]]
- [[Testing]]
- [[Redis]]
