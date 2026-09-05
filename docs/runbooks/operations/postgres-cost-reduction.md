# TSW-92 database cost rollout

The user authorized all actions related to resolving TSW-92 on September 4, 2026.
Production rollout still requires Development acceptance and the recovery gates below.
Run migrations only through Database Migrator. The concurrent index migration
fails closed unless its surviving unique index is valid and equivalent.

## Baseline and workload

Capture `scripts/capture-postgres-cost.sql` with `psql -X -f` before and after
each step, using private connections. Keep credentials out of evidence. Use WAL
and statement counter deltas over matching periods; discard a delta spanning a
stats reset. Record Railway CPU/RAM, volume and bucket bytes, and service egress
alongside generation age, terminal/expired queue backlog, actionable oldest age,
and authenticated bootstrap/feed latency. Include all services in cost totals.

The approved profiles are five-minute ranking and two-hour expiry for **new**
generations; existing generations retain their promised expiry. Disable
non-serving external-signal shadow rankings on Coordinator. Do not change worker
replicas while establishing this baseline. Circle caches are disposable Redis;
hides, read state, recovery anchors and the source corpus remain durable.

## Development WAL tuning

First verify at least 16 GiB free above current usage and LZ4 support with a
session `SET wal_compression = 'lz4'`. Record all previous values for rollback.
Apply separately, outside a transaction, to **Development**:

```sql
ALTER SYSTEM SET wal_compression = 'lz4';
ALTER SYSTEM SET max_wal_size = '8GB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
SELECT pg_reload_conf();
```

Verify effective settings in a new session. Preserve fsync, full_page_writes,
archive_mode and archive_timeout. max_wal_size is a soft checkpoint threshold,
not a storage cap. Leave work_mem/shared_buffers unchanged initially. Replay
representative ingestion with concurrent ranked reads; compare before/after
over one hour and a full day. Validate crash recovery in an isolated copy.

After the write reduction passes, test Development memory limits 4 then 2 GB;
Production's approved later sequence is 16, 12 then 8 GB. Keep the lowest level
that passes a representative load and a 24-hour soak. Revert immediately on OOM,
growing actionable queue age or >10% p95 latency regression. No whole-database
rewrite; normal vacuum reuses space and targeted index rebuilds need headroom.

## Backup gate

Production's intended **effective** pgBackRest settings are:

```text
repo1-retention-full-type=time
repo1-retention-full=7
repo1-retention-archive-type=full
```

Use the image contract `WAL_BACKUP_RETENTION_FULL=7`, native
`PGBACKREST_REPO1_RETENTION_FULL_TYPE=time`, weekly fulls (168 hours), and daily
differentials (24 hours); remove test-only seconds overrides. Leave explicit
archive-retention unset so the full backups pin their required WAL. Verify native
environment precedence against the effective pgBackRest command before expiration.
Weekly fulls retain roughly 7–14 days of history. Preview `expire --dry-run` and
restore a seven-day-old point before changing retention. Never use bucket TTLs or
manual WAL deletion. Keep gap recovery enabled; correlate its extra differentials
with archive timeouts, queue health, and repository continuity. Current zero lag
does not prove historic coverage. Inventory obsolete archive prefixes separately.

For Development, configure daily-only Railway volume backups with Railway's
six-day retention (explicitly accepted on September 4, 2026). Restore one through the **same volume-backup mechanism** into
an isolated target before retiring Development PITR. A PITR restore alone is not
evidence that the replacement daily-backup path works. Preserve old archives until
the replacement restore is verified. Inspect staged changes so disabling PITR
cannot silently delete needed history or deploy unrelated changes.

## Acceptance evidence

Run the repository restore-drill checks on isolated targets only. Record source
recovery time, actual replay stop time, migrations, representative content and
durable user-state checks, plus restart/rebuild completion. Discovery must recover
within one hour; test several points around archive failures, not merely an archive
start/end range. Never report restored user state from an empty cache as success.

At 24 hours and seven days, compare total DB-related cost against the recorded
baseline. Targets are >=70% cost reduction, >=80% WAL/upload reduction, >=95%
fewer retained ranking rows, no growing queue age, no lost read state or hides,
and no user-visible latency regression. These are acceptance targets, not measured
savings until the hosted soak completes. Keep Production unchanged if Development
acceptance or recovery gates fail.

## Implementation evidence — September 5, 2026 UTC

- Development WAL trial applied and verified: LZ4, 8192 MB max WAL, 900-second
  checkpoints, completion target 0.9; fsync and full-page writes remain on. No
  restart is pending. Preflight found approximately 87 GB free. Rollback values
  are compression `off`, max WAL `1GB`, checkpoint timeout `5min`, target `0.9`.
- Development safety volume backup `54357efb-ec88-46e9-820d-82f41319abfc` was
  created before testing replacement daily backups. Its restore is not yet
  verified. PITR and the existing schedule remain in place until that gate passes.
- Isolated Production restore service `tsw92-production-restore-drill`
  (`7cbb895a-2e6d-471e-9e2c-7bbb019ee2cb`) targets August 29, 03:00 UTC, using
  the August 26 full backup. Base restore completed and WAL replay started;
  recovery coverage is **not yet verified**. Source Production is unchanged.
  Record and remove the temporary restore service/volume after evidence is saved;
  account for drill compute/storage separately from steady-state savings. The
  temporary Development manual backup should also be retired after the replacement
  backup policy is verified, since manual backups do not expire with that policy.
- At 04:22 UTC the **isolated restore clone only** was tuned to asynchronous WAL
  fetching, two pgBackRest processes, and a 128 MiB fetch queue. A 119-second sample
  improved from 14.3 to 22.6 MiB/s (about 58%). Durability and the recovery target
  remain unchanged, with approximately 61 GB disk free. Rollback copies with
  `.tsw92-rollback` suffix are stored alongside the clone's edited configuration
  files. The saved 8 GB max WAL and 15-minute checkpoint settings are **not effective
  during bootstrap recovery**: the image starts Postgres with overriding 512 MB
  max WAL and 30-second checkpoint arguments. No restart was attempted. Source
  Production retains its original settings. Large historic WAL volume still
  implies hours-to-days; this short sample cannot establish a recovery-time promise.
  The wrapper regenerates the recovery pgBackRest config at boot, so the async
  change is not deployment-persistent. Future replay boots expose
  `PITR_RECOVERY_CHECKPOINT_TIMEOUT` and `PITR_RECOVERY_MAX_WAL_SIZE`; the default
  overrides intentionally constrain replay disk growth. After promotion, an
  ordinary boot may use the saved 8 GB/15-minute settings. Re-verify all settings
  after any clone restart.
- A Production `pgbackrest expire --dry-run` using time-based seven-day retention
  succeeded. It would remove the August 12 and 19 full backups and retain August
  26 and September 2, with required WAL retained from the August 26 backup.
  No backup or WAL was deleted. Run as the `postgres` OS user, not root.
- Web: 704 tests, typecheck, lint, and production build pass. Apple: simulator
  app build and all 129 unit tests pass. Full contract suite: 118 tests pass;
  four additional opt-in PostgreSQL index-preflight cases pass against an
  isolated PostgreSQL 18 database. Full migration chain and rerun pass.
- Swift suites pass: Wire 152, WireCore 90, ThinAppView 230,
  AppView 113, OperationsCore 64, including applicable PostgreSQL integration;
  affected service consumer suites also pass.
  Go race tests and vet pass, with 58.5% total statement coverage.
- Graph maintenance now runs as a separate serial child task under the existing
  Coordinator lease, keeping its six-hour cadence. Required rollups remain before
  ranking publication. Cost instrumentation uses bounded two-second statements,
  one sample per minute, and explicitly marks capped expiry counts as lower bounds.
- Application deployment, required hosted CI, authenticated Development QA,
  representative replay, memory trials, restore acceptance, and 24-hour/seven-day
  cost comparisons remain release gates. No measured savings are claimed.

Track updates in TSW-92 and its TSW-93, TSW-94, and TSW-95 children. Do not use
`railway postgres pitr backup restore` as a staging-only command: it commits the
volume replacement after copying. Review the underlying staged restore workflow
before any attempt to isolate a volume-backup drill.
