# Metadata Scheduling Projection Trial

The scheduling projection is implemented as a **disabled experiment**. The first
mixed-write replay failed its activation gates. Neither its triggers nor its
reader should be enabled in Production based on these results.

`wire_metadata_priority_work` holds narrow scheduling fields and separate
`item_present`/`cache_present` flags. It has no foreign key. Deferred item/cache
triggers insert placeholders and update only their source's fields. Conflicting
first inserts merge through the primary key without overwriting the other source.
Deletes clear their own fields; bounded indexed cleanup removes both-absent rows.
Canonical-key changes clear the old source group and fill the new group.

The reader retains the original batch limit, 75% priority allocation, exact signal/
retry/key ordering, general-lane refill, authoritative item eligibility rechecks,
and authoritative cache lock checks.
Lease renewal and completion fencing are unchanged.

## Defaults and Trial Sequence

- The schema migration installs synchronization and truncate-invalidation triggers
  **disabled**. A separate nontransactional Migrator step builds the priority index
  concurrently and checks that it is valid and ready.
- `WIRE_METADATA_SCHEDULING_READ_ENABLED=false` selects the original reader.
- `WIRE_METADATA_SCHEDULING_MAINTENANCE_ENABLED=false` disables experimental
  projection backfill/parity/cleanup work.
- Missing-cache repair runs independently on the rank Coordinator, at most 1,000
  rows per page, with `WIRE_METADATA_REPAIR_INTERVAL_MS=2000` between pages. Its
  existing durable cursor survives lane restarts. This replaces repair-on-claim.
  The theoretical ceiling is 1.8 million rows/hour before query time; the actual
  full-corpus sweep and discovery rebuild still need a measured one-hour test.
  Bounded logs report actual rows scanned/repaired, accumulated database wait and
  execution time, and the last fully observed sweep duration. A restarted loop
  waits for a complete cursor wrap before timing a full sweep. An unchanged empty
  cursor does not get a timestamp-only update.

On an explicitly disposable trial database, enable tracking only through
`SELECT wire_metadata_schedule_set_tracking(true)`. The function takes source
write locks, resets readiness/cursors, clears only the disposable projection, and
enables both deferred triggers atomically. Keep the reader flag false while the
maintenance flag backfills independent item/cache passes of up to 500 rows each.
Each pass locks its source rows, updates only that source's fields, and commits
before acquiring the other source's locks. Failed transactions leave committed
cursors recoverable. Skipped rows are revisited after a failed parity pass.

A consistent full parity check marks `read_ready` only when both source passes
complete with zero mismatches. This is a **correctness gate, not a performance
approval**. Only enable the reader flag after separately passing the workload
gates below. Readers also require enabled triggers and the validated current
`pg_postmaster_start_time()` epoch. A database restart immediately invalidates
readiness; source `TRUNCATE` also invalidates coverage. Trial maintenance resets and rebuilds the logged projection before
revalidation, protecting against loss of unlogged source rows. Without maintenance,
the reader continues using the original path.

Rollback: disable the reader and maintenance flags, then call
`SELECT wire_metadata_schedule_set_tracking(false)`. Do not toggle triggers
manually: reactivation must reset coverage rather than trust a stale disabled
epoch. Nothing here changes source retention, user records, or server recovery
controls.

## Reproducible Mixed-Write Replay

Provide `TSW_METADATA_REPLAY_DATABASE_URL` privately. The runner accepts only a
loopback PostgreSQL URL with a disposable `tsw114_*` database name, and replaces
only its `tsw114_schedule_replay` schema:

```sh
python3 scripts/benchmarks/metadata_schedule_replay.py \
  --rows 100000 --repeats 3 --output /tmp/metadata-schedule-replay.json
```

It applies the actual migration and uses its actual triggers. Each sample performs
1,000 item-signal updates, 1,000 metadata retry updates, 1,000 cache updates that
do not affect scheduling fields, and 128 metadata claims. Constraints are made
immediate within the replay transaction so rollback cannot hide deferred-trigger
cost. This changes trigger timing for measurement and is not a concurrent-writer
test; Swift integration fixtures exercise normal deferred execution separately.

September 12, 2026: PostgreSQL 18, 100,000 rows, three alternating repetitions.
The final query includes the authoritative item eligibility recheck. All exact
claimed-key comparisons and source-truncate invalidation checks passed. Median
summed database execution time:

| Distribution | Existing Mixed Work | Scheduling Mixed Work | Existing Claims | Scheduling Claims |
|---|---:|---:|---:|---:|
| Sparse Due | 41.50 ms | 71.89 ms | 17.30 ms | 22.73 ms |
| Dense Due | 27.53 ms | 53.37 ms | 4.53 ms | 3.90 ms |
| Tied Signals | 51.47 ms | 56.53 ms | 25.93 ms | 4.63 ms |
| Mostly Null Signals | 55.26 ms | 85.91 ms | 22.40 ms | 25.74 ms |

Claims improve in dense/tied distributions and regress in sparse/null cases;
trigger maintenance increases total execution time in every distribution. Median
priority buffer accesses change by +75%, -71%, -23%, and +77% respectively, failing
the required 80% reduction.
This is elapsed database time, **not measured CPU consumption**. Observed
whole-cluster WAL deltas were approximately 1.40 MB versus 2.47 MB per mixed
sample. Other local test databases share this cluster, so those WAL numbers may
include concurrent activity and do not establish an isolated WAL percentage.
They provide no basis for claiming the write-overhead gate passed.

Keep tracking and the reader off until representative replay demonstrates at least
80% fewer priority buffer accesses, p95 no worse than 110% of baseline across
supported scenarios, measured mixed-workload CPU and WAL no worse than 105% of
baseline, and no sustained actionable backlog. Require an otherwise idle isolated
cluster for whole-cluster WAL comparison, plus full-corpus restart/recovery and
one-hour discovery verification. These synthetic results fail activation; they do
not demonstrate Production memory or billing savings.

## Local Correctness Verification

The actual Database Migrator Docker image completed the entire migration chain
against an empty PostgreSQL 18 database, then completed an idempotent second pass.
Both new versions were recorded; the priority index was valid and ready; all four
synchronization/invalidation triggers and tracking/readiness remained disabled.
The complete Wire suite passed 305 tests, including concurrent placeholder merging,
rollback, locked-row behavior, source deletion, restart epoch mismatch, backfill
parity, stale projection eligibility rejection, and independent repair progress.
