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

- PR [#314](https://github.com/Stygian-Tech/the-social-wire/pull/314) merged into
  Development as `c3150a02e8fe7fed2960c8c50572c5be0715036d` after all required
  CI passed. All affected Development services deployed that revision. Database
  Migrator completed at 04:50:53; direct SQL verified both surviving unique
  ranked-item indexes are valid and `pg_stat_statements` 1.12 is installed.
  A new generation has exactly two hours of retention; older generations still
  have their original 48-hour expiry. The extra legacy Wire worker now runs only
  its drain role, with observed processing and zero actionable backlog.
- Public smoke tests initially saw Wire 503/stale responses during an upstream
  Production ranking-task restart. Both environments subsequently returned the
  same non-degraded ranked generation, with sampled latency 0.440 seconds in
  Development and 0.263 seconds in Production. This verifies the normal remote
  Corpus Edge path, not local ranking capacity or authenticated user acceptance.
  Production source checks at 05:01 confirmed its August 30 postmaster start,
  archiving on, compression off, 1 GB max WAL and five-minute checkpoints.
- Development WAL trial applied and verified: LZ4, 8192 MB max WAL, 900-second
  checkpoints, completion target 0.9; fsync and full-page writes remain on. No
  restart is pending. Preflight found approximately 87 GB free. Rollback values
  are compression `off`, max WAL `1GB`, checkpoint timeout `5min`, target `0.9`.
- Development volume backup `54357efb-ec88-46e9-820d-82f41319abfc`, taken at
  04:15:57 UTC, was restored through Railway's volume-snapshot mechanism into an
  isolated clone after a disposable marker fixture proved the staged rewire safe.
  The clone reached SQL readiness at 04:49:20 (snapshot age 33m23s; startup and
  crash recovery about five seconds) and restarted successfully at 04:51:44.
  After restart, bounded comparisons matched 1,000 read marks, 25 content URI/CID
  pairs, 100 logged Wire items, and 100 historical recovery anchors. Circle hides
  were empty. These samples establish retained rows, not exhaustive integrity.
  Schema verification passed for all 54 backup-time migrations; Development had
  advanced to 56. The newest restored operations heartbeat was 04:15:57.178692;
  the exact last committed transaction timestamp was unavailable. Discovery
  reconstruction within one hour remains a separate replay gate.
  Daily-only scheduling is now effective (`21 1 * * *`, UTC), with Railway's
  [six-day retention](https://docs.railway.com/volumes/backups). Existing weekly
  snapshots retained their original September 11/18/25 expiration dates;
  manual snapshots remain non-expiring. Source Postgres restarted at 04:56:47:
  archiving is off, LZ4/8 GB/15-minute tuning and fsync/full-page writes remain
  enabled, and the bounded inbox sample fell from 171 to zero. Its original
  volume remains mounted. The exclusively Development PITR bucket (137.836 GB,
  71,218 objects) was retired using Railway's supported environment-scoped bucket
  deletion after confirming no service references in either environment;
  Production's distinct bucket remains present. Retain the verified manual
  snapshot until the first scheduled daily snapshot exists and is usable, then
  delete that manual snapshot after the follow-up verifies those conditions. This is a concrete
  cleanup condition, not a requirement to retain the retired PITR archive.
  The temporary restore service was removed after evidence capture; its detached
  volume is pending Railway deletion on September 7 at 05:00 UTC. Final staged
  changes are empty. Provider deletion grace periods mean this is retirement
  evidence, not proof of an immediate billing reduction.
- Isolated Production restore service `tsw92-production-restore-drill`
  (`7cbb895a-2e6d-471e-9e2c-7bbb019ee2cb`) targets August 29, 03:00 UTC, using
  the August 26 full backup. Base restore completed and WAL replay started;
  recovery coverage is **not yet verified**. Source Production is unchanged.
  Record and remove the temporary restore service/volume after evidence is saved;
  account for drill compute/storage separately from steady-state savings. The
  temporary Development manual backup should also be retired after the replacement
  backup policy is verified, since manual backups do not expire with that policy.
- At 04:31 UTC on September 5, the **isolated restore clone only** was redeployed
  as `c0d5a612-708b-44d6-a25a-f8f180608143` with persistent service variables
  `PITR_RECOVERY_CHECKPOINT_TIMEOUT=15min`, `PITR_RECOVERY_MAX_WAL_SIZE=8GB`,
  `PGBACKREST_ARCHIVE_ASYNC=y`, `PGBACKREST_PROCESS_MAX=2`, and
  `PGBACKREST_ARCHIVE_GET_QUEUE_MAX=128MiB`. Actual postmaster arguments and
  archive-get logs confirm these settings are effective, overriding the image's
  default recovery-only 512 MB/30-second limits. Recovery source and target
  fingerprints match their pre-restart values; fsync, full-page writes, and
  checkpoint completion target 0.9 are preserved. The 04:32:15–04:34:13 UTC
  sample replayed at **32.09 MiB/s**, versus 14.30 baseline and 22.61 with async
  fetching alone. At 04:36:48 UTC a restartpoint reclaimed 252 WAL segments
  (approximately 3.94 GiB); at 04:37 UTC pg_wal occupied 5.2 GiB, with 57 GB disk
  free and 2.76 GB memory used. Replay was still processing August 26 transactions;
  reaching the August 29 target, integrity checks, seven-day recovery coverage,
  and the separate one-hour discovery rebuild test remain **unverified gates**.
  Source Production settings and retention are unchanged. Keep monitoring replay
  and disk headroom: max WAL is a soft recovery limit, and this short throughput
  sample is not a recovery-time promise. Re-verify settings after any clone restart.
- A Production `pgbackrest expire --dry-run` using time-based seven-day retention
  succeeded. It would remove the August 12 and 19 full backups and retain August
  26 and September 2, with required WAL retained from the August 26 backup.
  No backup or WAL was deleted. Run as the `postgres` OS user, not root.
- A bounded Production bucket-prefix inventory found only `pgbackrest/`, with
  one cluster prefix matching the active system identifier. pgBackRest reports
  one stanza and archive history `18-1`, with four full and fourteen differential
  backups. No abandoned cluster prefix was found. Backup repository deltas total
  approximately 91.3 GB; WAL objects were not enumerated in this metadata check.
- Read-only Production watcher tracing matched six 60-second asynchronous
  archive-push timeouts to six recovery-triggered differential backups between
  September 4 01:13 UTC and September 5 00:40 UTC. Each entry had catalog lag
  zero and recovered without an async-daemon kill. For the latest event, WAL
  `000000010000090F00000006` timed out at 00:40:18.592, succeeded on retry at
  00:40:20.228, and triggered a differential at 00:41:23. The installed watcher
  enters recovery on any increase in the archive failure counter, then takes a
  differential when the catalog advances. This explains repeated backups after
  transient errors; it does not prove historical continuity or justify disabling
  gap recovery. Effective archive-push uses three processes, a 5120 MiB queue,
  and zstd level 3. Reduce WAL pressure first, then measure timeout/backup
  frequency and verify continuity before considering watcher changes.
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
- An explicitly synthetic local capacity trial used the exact baseline and
  candidate revisions, sequentially on an isolated PostgreSQL 18 instance. Each
  revision published 5,000 candidates in each of three cycles. Durations were
  2464/2296/2439 ms before and 300/279/276 ms after (about 88% lower). Insertion-LSN
  WAL deltas were 9,552,664 and 7,441,344 bytes (about 22% lower). Short-interval
  `pg_stat_wal` publication lag made its candidate delta unsuitable for this
  comparison. This capacity fixture does not establish real-workload distribution,
  full Production capacity, or Railway spend reduction. The separate matched
  public archive pilot is recorded below.
- The matched **publication-only** public archive pilot completed at 05:42 UTC.
  Both exact revisions passed the same 900-second observation, drained all 3,719
  events (3,267 publication-profile commits plus 452 account events), and ended
  with zero actionable rows or dead letters. The identical seed contained four
  genuine public document items and eight aliases, preserving their original
  dates and CIDs; no popularity signals were fabricated. WAL was 88,343,442 bytes
  before and 46,103,737 after (47.8% lower). Ranked-item inserts were 42,435 versus
  6,242 (85.3% lower); successful local ranked reads were 166 versus 118, with
  p95 12.45 ms versus 12.97 ms (4.2% higher). Both ended with 3,222 candidates and
  2,687 ranked items. The candidate published two observed nonempty generations
  and retained the configured two-hour expiry. The five-second probe interval,
  small seed and publication-only profile do not establish full-social capacity,
  one-hour corpus reconstruction, or Railway savings. Partition-parent signal
  counters are not total signal counts and must not be interpreted as zero.
  This initial harness did not align checkpoint phase before each variant:
  database cleanup forces a checkpoint. Its WAL percentages include that timing
  effect and must not be treated as a precise causal estimate of application savings.
- The full-social public archive pilot completed at 14:59:56 UTC. Both variants
  passed fixed 900-second observations using the same 26,047-item public seed,
  isolated actor key and sealed four-minute archive interval. Each admitted
  10,958 inbox events and ended with no actionable rows or dead letters. Exact
  partition-spanning signal totals matched at 33,218: 30,226 shares, 704 quotes,
  1,794 likes, 453 reposts and 41 publications. The seed checksum was
  `a365cdcfb818f013fed935bbedd451ae1188e920869670f38041951fc48f850a`;
  archive segment `seg_00000005pf.jss` had checksum `40d130ff4777de1e`. Provider
  compaction changed this segment since the earlier publication pilot, so the
  pilots are different fixtures and their absolute totals are not comparable.
  Only 1,924 upcoming like/repost events referenced seeded link targets; this
  limited reference coverage does not represent Production's full social graph.
  Ranked inserts were 728 before versus 102 after; rollup inserts were 406,323
  versus 80,424. Both served 5,000 candidates, with 50–58 eligible ranked items.
  Successful local ranked reads were 152 versus 118; p95 was 6.59 versus 6.41 ms.
  Cold first-ranked readiness increased from 136.3 to 308.6 seconds. Candidate
  generation starts were 300 seconds apart and completed in about 6–7 seconds.
  WAL was 176,125,707 versus 123,372,386 bytes (29.95% lower), but cleanup changed
  checkpoint phase between variants. A retained candidate middle/tail WAL slice
  was 82.35% full-page-image bytes, supporting a separate LZ4/checkpoint trial.
  Sampled database CPU and working memory did not show savings (about 0.096
  versus 0.099 cores and 350 versus 418 MiB); the database had a two-CPU/two-GiB
  local limit and workers ran outside it. These are not Railway memory trials.
  Item insert counters differed by two rows (27,195 versus 27,193), so exact
  corpus parity is not established by the matching signal totals. External
  metadata, warm-cache order, small eligible rankings and checkpoint phase limit
  causal attribution. The corrected harness now checkpoints before measurement
  and records WAL LSN/checkpointer boundaries for newly started trials.
- TSW-98 tracks the hosted verification finding that database cost metrics were
  collected only when the Operations overview was read. PR
  [#315](https://github.com/Stygian-Tech/the-social-wire/pull/315) merged to
  Development at 14:16:49 UTC as `b2d1d1c2467547f4faf239917197126e835b5d51`
  after all CI passed. Its dedicated serial collector passed 31 Operations,
  64 OperationsCore, and eight PostgreSQL telemetry integration tests. A
  dashboard-closed control at 14:12:26 found no database metric rows in the
  preceding 15 minutes. Hosted verification at 14:40:50 found 15 consecutive
  minute buckets (14:26–14:40), each with 70 metric rows across 16 metric names
  and exactly one sample per series, without dashboard reads. Operations deployment
  `9b9c04e0-c74a-4349-b0c9-e227339c084b` runs the merged revision. The latest WAL
  sample was 41,639 bytes/second; this establishes collection, not savings.
- Live connection attribution found ten unnamed clients belonging to Coordinator,
  Projection Pool, and the legacy Wire worker. The separate Wire database config
  now receives the host's service environment and supplies a sanitized, bounded
  application name without changing pool limits. All 157 WireWorker tests pass,
  including five new configuration tests. PR
  [#318](https://github.com/Stygian-Tech/the-social-wire/pull/318) passed required
  CI and merged at 14:35:10 as `78c8534793b9829455d8f7b00eda52356682e9fc`. All
  three affected Development services deployed successfully. At 14:41:39, zero
  database clients were unnamed; Coordinator had nine connections, Projection
  Pool six, and The Wire Worker two. Their five client addresses matched fresh
  service-private DNS answers, and connection starts matched the new deployments.
- Authenticated Development web QA verified nonblank Subscribed/Wire views,
  successful Wire pagination, and client recovery from a one-shot injected
  `CursorExpired` 410 through successful edition refreshes. The temporary fetch
  shim was removed. This is client fault injection, not proof of server expiry.
  Opening one previously unread RSS article wrote its read mark successfully;
  the exact timestamp survived reload. The application's read-state context
  restored only that article to unread (`deleteReadMark` 200), and reload confirmed
  removal. The card menu currently lacks an individual unread action. Circle's
  Development catalog remains `enabled=false`, so hosted Circle interaction and
  privacy acceptance are not claimed.
- Intermittent authenticated Wire `FeedUnavailable` 503 responses at 14:03–14:05
  matched six-second client-aborted Production Corpus Edge edition requests and
  a ten-second PostgreSQL connection-creation timeout. Responses recovered to
  200 at 14:05:57. Normal generation staleness returns degraded 200; the observed
  failures indicate upstream database/transport pressure. The exact blocked query
  was not logged. This remains a rollout acceptance limitation.
- At 14:44 UTC the isolated Production restore was still replaying, with REDO
  `264/F315D0E8`, 56 GB free, and 6.4 GB of WAL. Its latest logged completed
  transaction was August 27 at 01:02:58 UTC, short of the August 29 target.
  Archive reads continued advancing. SQL remains unavailable while the clone
  recovers with hot standby disabled; deployment health is not recovery proof.
- A billing checkpoint at 14:33 UTC recorded $91.54 in project service usage
  for September 2, 21:40:15 through October 2, 21:40:15. Postgres accounted for
  $83.18, including $49.11 in service egress, $21.58 in memory, $9.53 in CPU,
  $0.80 in volume storage, and $2.16 in backups. The isolated Production restore
  added $1.24 separately. These accumulating period totals are not a matched
  before/after comparison. Include Redis, workers and deleted-resource charges
  when comparing equal windows. At 14:34, the Production archive contained
  3,448,822,905,854 bytes across 648,165 objects. Railway's
  [bucket billing](https://docs.railway.com/storage-buckets/billing) charges
  $0.015 per GB-month and service egress for uploads: holding that size for
  30 days would be about $51.73 in bucket storage alone. This is a size-based
  estimate, not invoiced usage; reconcile bucket charges with billing records
  rather than assuming the service subtotal includes them.
- Complete authenticated acceptance, representative replay, memory trials, Production
  restore acceptance, discovery rebuild timing, and 24-hour/seven-day cost
  comparisons remain release gates. No measured billing savings are claimed.

Track updates in TSW-92 and its TSW-93, TSW-94, and TSW-95 children. Do not use
`railway postgres pitr backup restore` as a staging-only command: it commits the
volume replacement after copying. Review the underlying staged restore workflow
before any attempt to isolate a volume-backup drill.

The tested API procedure is: call `volumeInstanceBackupRestore`, wait for its
cloned volume and staged mount replacement, assert the patch contains only that
restore, and replace it with a target-service-only mount patch. Commit that
explicit patch with `environmentPatchCommit`; never commit all staged changes.
Preserve the source service's original mount and match the clone's region to the
source volume. Inspect and clear only the known residual staged patch afterward:
explicit patch commits do not consume staging automatically. A custom start
command must retain the image's `tini`/`wrapper.sh` entrypoint so PostgreSQL runs
as its service user. Distinct service/volume identities establish isolation;
physical snapshots correctly share the PostgreSQL system identifier. Delete
temporary services and explicitly delete their confirmed-owned volumes after
evidence is saved; service deletion alone can leave billable detached volumes.
