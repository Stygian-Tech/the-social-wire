# Supabase to Railway Postgres Migration

This runbook copies Social Wire's application-owned PostgreSQL data from managed Supabase into the
schema already managed by `supabase/migrations` on Railway. It does not import Supabase-managed
`auth`, `storage`, realtime, internal roles, ownership, or grants.

Use a maintenance-window dump/restore for the final cutover. `pg_dump` produces a transactionally
consistent snapshot, but exact source/target verification requires all database writers to remain
paused from the start of the final export until validation finishes.

## Prerequisites

- PostgreSQL client tools at least as new as the Supabase server (`psql`, `pg_dump`, `pg_restore`)
- `railway` CLI linked to **The Social Wire** (the command examples select an environment explicitly)
- `jq`
- Supabase direct connection URL, or the session-pooler URL on port 5432
- Enough local disk for a compressed data-only dump
- Railway Postgres migrations fully applied

Never use the Supavisor transaction pooler on port 6543 for `pg_dump` or `pg_restore`.

```bash
export SUPABASE_SOURCE_DATABASE_URL='postgresql://...'
export RAILWAY_ENVIRONMENT=dev
bash scripts/migrate-supabase-to-railway.sh preflight
```

Preflight is read-only. It checks PostgreSQL/client versions, source size, public-table equality,
exact `supabase_migrations.schema_migrations` equality, unexpected application-owned schemas, and
PostgreSQL large objects. Any unsupported data or schema drift must be resolved before copying data.

## Rehearsal

A rehearsal can export while Supabase remains live, but source counts may advance after the dump's
snapshot. Do not treat a rehearsal count difference as final-cutover failure until writers are
paused.

```bash
bash scripts/migrate-supabase-to-railway.sh export
```

Artifacts are written beneath `.migration-artifacts/supabase-to-railway/` and ignored by Git. The
archive contains `public` schema data only. Keep it protected because it contains production data.

The Railway `dev` environment is the isolated rehearsal target. It has its own Postgres volume and
all repository-backed services track the `dev` branch. Keep rehearsal artifacts separate from the
final production export:

```bash
railway down --yes --service Gateway --environment dev
railway down --yes --service 'App View' --environment dev
railway down --yes --service Charybdis --environment dev
railway down --yes --service Ops --environment dev
railway down --yes --service Tap --environment dev

export RAILWAY_ENVIRONMENT=dev
export MIGRATION_ARTIFACT_DIR='.migration-artifacts/supabase-to-railway-dev'
export MIGRATION_WRITERS_PAUSED=YES
export MIGRATION_CONFIRM_TARGET_RESET='The Social Wire/dev/Postgres'

bash scripts/migrate-supabase-to-railway.sh migrate
```

Do not use `MIGRATION_WRITERS_PAUSED=YES` as a claim of source consistency during rehearsal unless
source writers are actually paused. It is accepted for a disposable target-only rehearsal because
the restore guard also protects against accidentally truncating the wrong database.

After a successful restore, start Dev in dependency order and run the application smoke tests:

```bash
railway redeploy --yes --from-source --service Tap --environment dev
railway redeploy --yes --from-source --service 'App View' --environment dev
railway redeploy --yes --from-source --service Ops --environment dev
railway redeploy --yes --from-source --service Gateway --environment dev
railway redeploy --yes --from-source --service Charybdis --environment dev
```

After rehearsal validation, unset the Dev overrides before the final production run:

```bash
unset RAILWAY_ENVIRONMENT MIGRATION_ARTIFACT_DIR MIGRATION_CONFIRM_TARGET_RESET
```

## Final maintenance window

### 1. Prevent new application writes

Put the public application into maintenance mode. Pause every old Fly process that writes or
projects Supabase data:

- `the-social-wire-prod-gateway`
- `the-social-wire-prod-appview`
- `the-social-wire-prod-appview-worker` (Charybdis)
- `the-social-wire-prod-operations`
- `the-social-wire-prod-tap`

Also stop the corresponding Railway database writers before resetting the destination:

```bash
railway down --yes --service Gateway --environment production
railway down --yes --service 'App View' --environment production
railway down --yes --service Charybdis --environment production
railway down --yes --service Ops --environment production
railway down --yes --service Tap --environment production
```

The two frontend services do not connect directly to Postgres and may remain running behind their
temporary Railway domains. Postgres itself must remain running.

Confirm there are no CI jobs applying migrations and no operator backfills in progress.

### 2. Export, reset, restore, and verify

The `migrate` command creates a temporary Railway TCP proxy if one does not exist, removes only the
proxy it created on exit, truncates all source-owned public tables in one transaction, restores the
data, resets dumped sequences, runs `ANALYZE`, and compares exact row counts. It temporarily drops
and recreates source-unvalidated `public` check constraints as `NOT VALID`; PostgreSQL otherwise
enforces those constraints during `COPY` even when the source legitimately retains older rows that
predate the constraint.

```bash
export SUPABASE_SOURCE_DATABASE_URL='postgresql://...'
export MIGRATION_WRITERS_PAUSED=YES
export MIGRATION_CONFIRM_TARGET_RESET='The Social Wire/production/Postgres'
export MIGRATION_VERIFY_CHECKSUMS=1

bash scripts/migrate-supabase-to-railway.sh migrate
```

`MIGRATION_VERIFY_CHECKSUMS=1` performs a full content scan and sort for every table. Floating-point
columns are hashed from their stable PostgreSQL wire bytes so equal values remain comparable across
PostgreSQL major versions even when JSON number rendering changes. It is slower than row-count
verification but should be enabled for final cutover. The script never prints either database URL.

### 3. Start Railway in dependency order

```bash
railway redeploy --yes --from-source --service Tap --environment production
railway redeploy --yes --from-source --service 'App View' --environment production
railway redeploy --yes --from-source --service Ops --environment production
railway redeploy --yes --from-source --service Gateway --environment production
railway redeploy --yes --from-source --service Charybdis --environment production
```

Keep `TAP_CONSUMER_MODE=disabled` until the independent Tap shadow/parity gate is satisfied. Verify:

- Gateway `/readyz` returns 200.
- Gateway OAuth metadata documents return 200.
- App View and Ops logs contain no fresh PostgreSQL errors.
- Charybdis resumes its Jetstream cursor without a gap.
- Sidebar, bootstrap stream, unread counts, entry reads, and read-mark mutations work through the
  temporary Railway Gateway domain.

Create or confirm a Railway volume backup before changing public DNS. Railway's backup/PITR window
starts only after those features are enabled; it is not retroactive.

### 4. Change DNS

Switch Gateway first, then Operations Web and Web after Gateway validation. Use the CNAME targets
shown by `railway domain status`. Wait for Railway certificate status to become active before ending
maintenance mode.

## Rollback boundary

Before Railway accepts writes, rollback is DNS reversal plus restarting the Fly writers. After
Railway accepts writes, the databases diverge. Do not roll back to Supabase without first exporting
or otherwise reconciling the Railway-side delta. PDS-authored records remain canonical, but App View
read marks, ingestion cursors, caches, and operations state still require explicit reconciliation.

Retain Supabase read-only and retain the final dump until the Railway observation window and backup
verification are complete. Do not delete the Supabase project as part of the cutover.

## Why data-only

Railway already owns the application schema through this repository's migrations. A full raw dump
would also carry Supabase-managed schemas, reserved roles, ownership, and grants into a plain
PostgreSQL service. The data-only archive avoids those platform-specific objects while preserving
table rows and sequence values.
