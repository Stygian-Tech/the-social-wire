# TSW-92 database cost rollout

The user authorized all actions related to resolving TSW-92 on September 4, 2026.
Following the September 5 request to expedite, roll out in separate stages. The
tested application write reductions may reach Production after required release
CI passes, using the recorded Development deployment, replay, and authenticated
QA evidence with its stated limitations. Immediately verify Production service
health, authenticated feeds and read state, generation freshness, and ingestion
backlog and latency against the pre-deployment baseline; pause further rollout
and revert the affected application change on regression. This stage does not
change backup retention, WAL settings, or memory limits. On September 8 the user
replaced the Production seven-day PITR requirement with daily Railway snapshots
and accepted their six-day retention. The replacement snapshot restore and
discovery recovery gates below now govern PITR retirement. Memory limits
remain separate measured trials with the rollback criteria below. Outstanding
acceptance and savings evidence must not be reported as complete.
Run migrations only through Database Migrator. The concurrent index migration
fails closed unless its surviving unique index is valid and equivalent.

## Baseline and workload

Capture `scripts/capture-postgres-cost.sql` with `psql -X -f` before and after
each step, using private connections. Keep credentials out of evidence. Use WAL
and statement counter deltas over matching periods; discard a delta spanning a
stats reset. Record Railway CPU/RAM, volume and bucket bytes, and service egress
alongside generation age, terminal/expired queue backlog, actionable oldest age,
and authenticated bootstrap/feed latency. Include all services in cost totals.

The approved profiles are five-minute ranking and one-hour expiry for **new**
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

Verify effective settings in a new session. Preserve fsync and full_page_writes;
change archiving only through the separately verified backup cutover below.
max_wal_size is a soft checkpoint threshold,
not a storage cap. Leave work_mem/shared_buffers unchanged initially. Replay
representative ingestion with concurrent ranked reads; compare before/after
over one hour and a full day. Validate crash recovery in an isolated copy.

After the write reduction passes, test Development memory limits 4 then 2 GB;
Production's approved later sequence is 16, 12 then 8 GB. Keep the lowest level
that passes a representative load and a 24-hour soak. Revert immediately on OOM,
growing actionable queue age or >10% p95 latency regression. No whole-database
rewrite; normal vacuum reuses space and targeted index rebuilds need headroom.

## Backup gate

Production and Development use daily-only Railway volume snapshots with the
provider's six-day retention. This permits losing changes since the latest usable
snapshot, normally up to about 24 hours; it does not provide arbitrary point-in-time
recovery. Alert if no successful daily snapshot exists within 26 hours. Verify the
effective schedule, snapshot timestamps and expirations instead of inferring them
from a configured daily flag.

Before retiring an environment's PITR archive, restore a daily snapshot through
the **same volume-backup mechanism** into an isolated verifier. Railway's restore
operation stages a replacement of the source volume. Redirect only the verified
cloned volume to the verifier, commit an explicit verifier-only patch, and prove
the live volume and postmaster remain unchanged. Do not use the CLI restore flow
that automatically commits a live replacement. Remove archive/recovery credentials
from the verifier and explicitly disable its archive and restore commands before
startup. Preserve source corpus, read state, hides and recovery controls; verify
their integrity and repeat after restart. Rebuild discovery within one hour.

After the replacement proof, remove the six `WAL_ARCHIVE_*` variables from the
source through an explicit service-only Railway configuration change. Read back
`archive_mode=off`, preserved crash-safety/WAL tuning, the original mounted volume,
and daily snapshots after the controlled restart. Keep the old bucket until those
checks pass. Verify ownership and references in both environments before retiring
the exclusively owned archive bucket and obsolete restore service/volume through
Railway. Never manually delete WAL files from an active repository, apply bucket
TTLs, or commit unrelated staged changes. Account for temporary restore resources
and provider deletion grace periods separately from steady-state savings.

## Acceptance evidence

Run the repository restore-drill checks on isolated targets only. Record source
recovery time, actual replay stop time, migrations, representative content and
durable user-state checks, plus restart/rebuild completion. Discovery must recover
within one hour. Record snapshot creation, restore request, database readiness and
discovery readiness separately. Never report restored user state from an empty
cache as success. Historical PITR experiments below describe the policy at the
time and do not reinstate the superseded seven-day PITR gate.

At 24 hours and seven days, compare total DB-related cost against the recorded
baseline. Targets are >=70% cost reduction, cessation of PITR uploads, >=95%
fewer retained ranking rows, no growing queue age, no lost read state or hides,
and no user-visible latency regression. These are acceptance targets, not measured
savings until the hosted soak completes. Continue measuring local WAL generation
as a workload diagnostic; archiving being intentionally idle is not a failure.
The expedited application stage does not
waive these final acceptance checks. A failed recovery gate blocks retention
shortening; a failed workload or memory trial blocks the corresponding tuning or
limit change. Address observed application regressions before proceeding further.

## Implementation evidence — September 5, 2026 UTC

- Expedited Production application release [#320](https://github.com/Stygian-Tech/the-social-wire/pull/320)
  merged at 17:05:33 UTC as `c59279a5b571fecd51bfa30450f860eec1b98a7e`.
  All required CI passed; a failed-only retry resolved an Operations Web package
  extraction failure without source changes. The audited dev-to-main range
  contained only TSW-92 work. Production Migrator deployment
  `71ab66d5-eb05-46b2-a65f-507ab314f46a` succeeded: its index preflight, concurrent
  drop, and extension creation completed at 17:06 UTC. Subsequent cgroup memory
  was 15,742,050,304 bytes versus a pre-release sample of 23,401,086,976 bytes,
  with the 24 GB limit unchanged. These snapshots do not establish sustained
  savings or isolate all causes. All affected application deployments subsequently
  reached SUCCESS. Coordinator acquired its lease at 17:11:28 with external
  signals off and the wire-v10 serving algorithm preserved. Its first cycle
  completed at 17:14:31 in 183,075 milliseconds, publishing all 11 supported
  language buckets without shadow generations. English generation
  `776a8ca4-48da-48bd-9d0a-8d59beb53e5d` contained 3,207 items. Public feed and
  edition reads served this exact generation, ranked and non-degraded, in sampled
  0.257/0.351 seconds. Memory after the first cycle was 16,134,369,280 bytes,
  still with a 24 GB limit; this remains a short observation. Subsequent cadence,
  stored two-hour expiration, and direct SQL checks remain separate verification;
  the configured SSH signer was unavailable.
  Production Coordinator has explicit off/300/7200 shadow/cadence/retention
  settings for the new deployment. The legacy Production Wire worker already
  has the drain-only role. Backup retention and Production memory are unchanged.
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
- The first Development memory trial started at approximately 16:57 UTC:
  a service-scoped limit update reduced 16 GB to 4 GB while preserving the
  24-vCPU ceiling. The running container's limit became 3,999,997,952 bytes;
  usage fell from 5,070,540,800 to 3,981,946,880 bytes as file cache was reclaimed.
  No new deployment was created. Through 17:13 the OOM/kill/max counters remained
  zero, the original postmaster start was unchanged, and actionable backlog
  returned to zero after one transient 64-millisecond-old item. This is initial
  trial evidence, not representative-load or 24-hour acceptance. Restore the
  Development limit to 16 GB on the rollback conditions above. Do not advance
  to 2 GB or declare a Production memory limit validated from these samples.
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
  dates and CIDs; no popularity signals were fabricated. Reported WAL counter
  deltas were 88,343,442 bytes before and 46,103,737 after (47.8% lower). Ranked-item inserts were 42,435 versus
  6,242 (85.3% lower); successful local ranked reads were 166 versus 118, with
  p95 12.45 ms versus 12.97 ms (4.2% higher). Both ended with 3,222 candidates and
  2,687 ranked items. The candidate published two observed nonempty generations
  and retained the configured two-hour expiry. The five-second probe interval,
  small seed and publication-only profile do not establish full-social capacity,
  one-hour corpus reconstruction, or Railway savings. Partition-parent signal
  counters are not total signal counts and must not be interpreted as zero.
  This initial harness did not align checkpoint phase before each variant:
  database cleanup forces a checkpoint. Its WAL percentages include that timing
  effect and counter-visibility lag; they are not a precise causal estimate
  of application savings.
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
  versus 80,424. Both considered 5,000 candidates, with 50–58 eligible ranked items.
  Successful local ranked reads were 152 versus 118; p95 was 6.59 versus 6.41 ms.
  Cold first-ranked readiness increased from 136.3 to 308.6 seconds. Candidate
  generation starts were 300 seconds apart and completed in about 6–7 seconds.
  Reported WAL counter deltas were 176,125,707 versus 123,372,386 bytes (29.95%
  lower), but cleanup changed checkpoint phase and final counters can lag. A retained candidate middle/tail WAL slice
  was 82.35% full-page-image bytes, supporting a separate LZ4/checkpoint trial.
  Sampled database CPU and working memory did not show savings (about 0.096
  versus 0.099 cores and 350 versus 418 MiB); the database had a two-CPU/two-GiB
  local limit and workers ran outside it. These are not Railway memory trials.
  Item insert counters differed by two (27,195 versus 27,193). Actual item
  counts and identities were not captured, so this does not establish a corpus
  mismatch or prove exact corpus parity. External
  metadata, warm-cache order, small eligible rankings and checkpoint phase limit
  causal attribution. The corrected harness now checkpoints before measurement
  and records WAL LSN/checkpointer boundaries for newly started trials.
- The separate tuned candidate trial passed at 15:16:34 UTC after 900.47 seconds.
  It used the identical seed, archive, isolated actor key and candidate binaries,
  with verified LZ4, 8 GB max WAL, 15-minute checkpoints and completion target 0.9.
  Fsync/full-page writes, 128 MiB shared buffers and 4 MiB work_mem stayed unchanged.
  The new pre-observation checkpoint completed. The exact total remained 33,218
  signals, matching each kind's earlier count; final queue/dead-letter counts were zero.
  There were 118 successful ranked reads across two generations (50/53 items),
  with p95 7.02 ms and cold readiness 308.48 seconds. Direct final counts were
  27,191 items and 58,165 aliases; ordered identity hashes are retained privately.
  No OOM events occurred. This local fixture does not establish a Railway memory
  limit, archive-upload capacity, or full-corpus rebuild time.
  The measured insertion-LSN span was 102,960,096 bytes. Bounded WAL decoding
  found 101,911,926 record/image bytes: 45,508,015 record bytes and 56,403,911
  full-page-image bytes. The final cumulative counter delta was only 87,703,396
  bytes. Subsequent counters advanced 14,727,092 bytes while physical WAL grew
  just 500,688 bytes, demonstrating delayed visibility of earlier writes. Prefer
  physical interval evidence; the harness now records `wal_lsn_span_bytes` while
  preserving the explicitly documented legacy counter field. No original artifacts
  were rewritten. The earlier runs lack phase control and LSN boundaries, so the
  tuned result is not a clean before/after savings percentage. One timed checkpoint
  began near the observation boundary; none completed inside it. Crash recovery,
  WAL-size-triggered checkpoint pressure and the hosted soak remain unverified.
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
- At 15:09 UTC the isolated Production restore was still replaying, with REDO
  `26F/96724978`, 54 GB free, and 8.2 GB of WAL. Its latest logged completed
  transaction was August 27 at 01:59:14 UTC, short of the August 29 target.
  Effective `recovery_target_action=promote` means it should become queryable
  after reaching that target. `hot_standby=off` explains current SQL unavailability;
  `archive_mode=off` prevents normal clone WAL uploads after promotion. No active
  backup watcher was visible. Deployment health remains insufficient recovery proof.
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
  comparisons remain outstanding. The expedited application stage uses the
  existing CI and Development evidence plus immediate Production verification;
  it does not establish these remaining acceptance results. Seven-day restore
  acceptance still gates retention shortening, and measured memory trials gate
  each separate limit reduction. No measured billing savings are claimed.

## Production memory trial — September 7, 2026 UTC

The user explicitly authorized applying the Production memory reduction now.
The first step changed only Production Postgres's Railway memory limit from
24 GB to 16 GB; no source change or redeployment was required. At 04:24:34 UTC,
the running cgroup reported `memory.max=16000000000` and 13,325,697,024 bytes
used. This is a decimal 16 GB cap, not 16 GiB. Isolated comparison rounds must
set `memory_limit_bytes` to this exact value, then `12000000000` and
`8000000000` for the planned 12 GB and 8 GB steps. The CPU ceiling remained 24 cores (`cpu.max=2400000 100000`). OOM and
OOM-kill counters remained zero, and the memory-limit event count remained
7,868, unchanged from the immediate pre-change sample. SQL succeeded and the
postmaster start remained August 30 at 00:32:30 UTC: no database restart occurred.

This is initial trial evidence, not 24-hour acceptance or measured billing
savings. Restore the 24 GB limit on OOM, sustained latency regression, or growing
ingestion lag. Do not advance to 12 or 8 GB without evaluating the 16 GB trial.
Production WAL settings and backup retention were not changed by this action.
The Coordinator cancellation fix passed required CI and reached Production in
PR #325 at 05:08:40 UTC as `26eaf7c05c444472466fe4a944430402d07d8a96`.
Its watchdog recovers stalled shutdowns, but does not resolve the underlying
database contention. Deployment completion is not memory-trial acceptance.

### Backlog and write attribution

Record live statement deltas and queue diagnostics in TSW-92. Do not infer
memory exhaustion from Railway's memory chart alone. Measure OOM counters,
database waits and ingestion arrival/application rates together. The actionable
count includes FIFO-blocked followers, so report it separately from eligible
repository heads. Distinguish large publication batches from unresolved-reference
retries tracked by TSW-102.

The corrective application work targets changed-only atomic rollup publication,
indexed selection of eligible repository heads, and avoiding retired-generation
verification scans when no eligible recovery incident exists. Preserve source
events, leases, ordering, recovery checks, ranking values and durability. Validate
these changes with database integration and representative queue fixtures before
Development and Production rollout. Keep the 24 GB rollback available, but do not
claim that additional memory alone can fix repository ordering or repeated work.

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


## September 8 ingestion pressure correction

The 12 GB Production trial did not pass: two bursts exceeded 40,000 actionable
rows, oldest age exceeded 22 minutes, and a later small queue stalled during an
8.4-minute ranking cycle. The user authorized necessary corrective changes. At
approximately 16:39 UTC the Postgres ceiling returned to 16 GB, preserving 24 vCPU.
The running cgroup confirmed 16,000,000,000 bytes with zero OOM/kill events; the
postmaster still dates to August 30. Most memory was filesystem cache. This is a
rollback of a failed trial, not evidence that memory caused every stall.

Live waits included WALWrite/WalSync, with ingestion lease writers queued behind
those operations. Short statement deltas identified duplicate full inbox status
scans, while query plans showed account lifecycle updates scanning about 1.8
million Wire items and metadata claims sorting about 1.7 million cache rows.
Graph maintenance completed in about two seconds outside the stalled windows;
its cadence and ranking semantics are unchanged.

The corrective release adds concurrent author/metadata-priority indexes, combines
inbox status totals with their source breakdown, and coalesces observational inbox
reads for at most five seconds per store. Checkpoints, incidents, recovery and
fencing reads remain live. Telemetry metric writes use sorted 250-row batches,
a 500 ms lock wait, two-second statement limits and a five-second cumulative
write budget. That budget begins after pool acquisition and does not bound a
network failure or WAL-stalled commit. Contention tests require atomic rollback,
exact retry statistics and reusable pooled sessions.

At 16:44 UTC Production WAL tuning was applied and verified in a fresh session:
LZ4, 8192 MB max WAL, 900-second checkpoints and completion target 0.9. Fsync,
full-page writes and archiving remain on; global work_mem (4 MB) and shared buffers
(128 MiB) are unchanged. There was about 37 GiB free on the volume, and no restart
was required. Development already runs these settings. A separate PostgreSQL
18.6 local crash fixture retained exact committed fingerprints for 100,000 corpus
and 20,000 ranking rows, rolled back an interrupted transaction, restarted in
0.421 seconds, and passed offline checksums over 14,044 blocks. Its 121 MB WAL
volume does not prove an 8 GB recovery duration or Railway PITR coverage.

Monitor disk headroom (retain at least 16 GiB free), archive failures, WAL/upload
rates, queue age and feed latency. Roll back WAL tuning to compression off,
max_wal_size 1 GB and checkpoint_timeout five minutes if it causes regression;
completion target was already 0.9. Do not advance to 12/8 GB again until the
corrected workload passes a representative comparison. Production retention is
unchanged, and continuous seven-day recovery/discovery rebuild and matched cost
acceptance remain open. The code release requires separate Development and
Production deployment verification; these observations do not themselves prove
that a new revision is running.


### September 8 Production daily-backup cutover

Production PITR was disabled after a new daily-snapshot restore demonstrated usable discovery in approximately 46 minutes, including snapshot copy, migrations, bounded recovery, moderation refresh, signed private feed/edition responses, and database restart. The first drill failed its one-hour gate because full archive replay hit provider byte-rate limits; that result remains a failure. The successful repeat used retained logged publication fences and downloaded zero archive bytes. Its feeds correctly reported `degraded=true` while historical replay remained incomplete. This was service-to-service acceptance, not end-user OAuth/UI QA or complete historical signal parity.

The repeat preserved 1,000 sampled read marks, 534 read floors and one unread override across restart. Wire corpus and alias samples matched the source; every still-present sampled content record matched. Existing gap/backfill/recovery controls and hide tables remained logged and retained. The original Production volume stayed attached throughout both drills.

Production restarted at `2026-09-08T23:53:56.148777Z` with `archive_mode=off`. The six archive variables were removed through an explicit source-only configuration patch. `fsync`, full-page writes, LZ4, the 8 GB WAL allowance, 15-minute checkpoints and completion target 0.9 were preserved. Both actionable queues were clear. Seventy AppView dead letters predated the cutover (August 19 through September 1); no cutover dead letters were added or deleted.

The daily schedule remains 04:37 UTC with the accepted six-day retention and nine existing snapshots. The September 8 snapshot expires September 14. Continuous archive upload cessation and archive-resource deletion are separate evidence: cleanup was still underway at this checkpoint. Production cost PR #360 merged at `25b2381f8b0eb5a63e8d36e9e81d2f71e41a422e`; exact deployment verification remains required. The 16,000,000,000-byte Production cap is unchanged pending representative replay. No lower-cap acceptance or aggregate savings is claimed.

### September 9 clean restart verification

Shutdown PR #362 passed all required CI and merged as `66d3686f`. Production
deployment `16dbae59-ad65-4df9-b442-634f786e4354` preserves the Railway managed
image and its automatic vulnerability updates. Only the rendered startup adapter
and 120-second draining grace changed. The original running wrapper had 60 seconds
of grace but TERM requested smart shutdown, leaving pooled clients holding it open.

For the one-time handoff, the actual postmaster parent was verified as the vendor
wrapper and paused. PostgreSQL fast shutdown completed at 01:25:32 UTC; the new
instance accepted connections at 01:27:40 UTC, about 128 seconds later. Startup
reported the prior clean shutdown. Both unlogged Wire inbox epochs and recovery
jobs survived, along with the original cluster identity and volume. At 01:28:53,
publication ingestion was live and advancing at sequence `25633257393`, with no
pending, leased or retry work. The 461 historical Wire diagnostics and 70 old
AppView dead letters were retained. The external lane's pre-existing budget pause
and incomplete historical recovery acceptance are separate from this result.

PITR remains off. Fsync, full-page writes, LZ4, 8 GB max WAL, 15-minute checkpoints,
completion target 0.9, 4 MiB work memory and 128 MiB shared buffers were verified
unchanged. The 16 GB decimal memory cap remains pending representative load tests.
The isolated restored database is stopped; its volume remains for those tests.
Provider deletion grace still separates retired archive/volume deletion requests
from actual storage billing cessation. No net savings claim follows from this
restart proof.


### September 9 post-cutover recovery and cleanup

All required Production cost-release services subsequently reached success at `25b2381f`. The immediately clear queue was not sustained acceptance: the restart reset the unlogged inbox epochs and triggered historical recovery replay. Startup logs explicitly reported an interrupted database, followed by redo. The shutdown cause is under investigation; this was not a clean-restart proof. Publication recovery seeding progressed from retained fences while archive batches produced a bursty Wire backlog. At 00:19 UTC, about 8,000 pending events belonged to only three repositories. Repository ordering limited useful parallelism despite spare worker CPU; raising concurrency alone was not justified. Existing payloads, leases, version fences and terminal classifications remain preserved. AppView's 70 old dead letters remain distinct from newly classified historical Wire events. The queue gate remains open until replay catches up and live work stays current.

After the user explicitly approved permanent destruction, deletion of the retired PITR bucket was submitted and the bucket disappeared from both environment configurations. Provider metadata persists during Railway's 52-hour bucket restoration grace; permanent object removal and stopped storage billing are not yet verified. The old PITR verifier service was deleted, and its obsolete volume plus the failed first daily clone volume entered the provider's 48-hour volume deletion grace. Four fresh verifier deployments were removed, stopping their compute. The approximately 45 GB successful restore volume remains attached to a stopped verifier for memory testing and continues to incur storage cost. The original Production volume, daily schedule and nine listed snapshots were preserved. PITR remains off; the historical ingestion archive replay is a separate source and must not be mistaken for resumed backup uploads.


### Telemetry write migration (TSW-92, September 9)

`20260909130000_remove_redundant_telemetry_indexes.sql` removes only the duplicate
change-event replay, event identity, and trace identity indexes. All three are
checked against valid equivalent primary keys, including dependencies and replica
identity, before any concurrent drop. The migrator can retry after a partial run.
Rows, primary keys, expiry indexes, change-event watermarks, and trigger behavior
are preserved; no table rewrite or retention reduction is part of this migration.

The paired OperationsCore change inserts events and spans in bounded 250-row
chunks within the existing atomic metrics/events/spans transaction. This reduces
round trips while metric locks are held. Keep the existing two-second transaction
budget and 500 ms lock timeout. The previous writer remains compatible with the
migration, so an application rollback does not require rebuilding duplicate indexes.

Validate fresh/upgrade/retry migrations and PostgreSQL mixed-batch rollback,
concurrent writers, null IDs, retention timestamps, and environment isolation.
After Development and Production rollout, compare rollup lock timeouts, telemetry
export drops, query/WAL counter deltas, and actionable inbox age under equivalent
load. Index removal and batching do not establish a passing 12 GB memory limit.
