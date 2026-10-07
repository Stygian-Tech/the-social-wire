# PostgreSQL 4 GB Preparation (TSW-155)

This patch prepares a measured 4 decimal GB experiment. It does not change hosted
settings, backfill live data, enable experiments, or establish capacity acceptance.
Live infrastructure identifiers and diagnostic snapshots remain in the private
issue/evidence record rather than this public source document.

## Precompute Qualification

Metadata writes maintain the exact non-time Open Graph admission predicate in
`open_graph_qualified`. Source/status checks and the original seven-field null
count are unchanged. Expiry remains evaluated against `stale_until` at query time.
The trigger covers direct SQL writers and explicit qualification assignments.

An additive nullable column avoids a table rewrite. Disjoint known-TRUE and
legacy-NULL query branches preserve reads throughout backfill. A partial covering
index permits narrow reads of qualified keys; a partial NULL index bounds pending
backfill selection. Concurrent migrations repair invalid interrupted builds and
reject object-name collisions.

Run each backfill batch through an authorized database connection, setting the
statement timeout before calling the function (setting it inside a function cannot
bound the containing call):

```sql
BEGIN;
SET LOCAL statement_timeout = '2s';
SET LOCAL lock_timeout = '500ms';
SELECT wire_backfill_metadata_qualification(500);
COMMIT;
```

The function permits 1–5,000 rows and uses `FOR UPDATE SKIP LOCKED`. A zero batch
can mean remaining rows are locked; verify no NULL qualification rows remain with
a bounded diagnostic before declaring completion. Pace independent committed
batches and monitor latency, locks, replication/WAL and ingestion.

A separate concurrent partial representative-URI index supports record retraction
lookups without changing update/delete semantics. Database migrations remain owned
by Database Migrator.

## Local Evidence and Limits

A 20,000-row metadata fixture measured 5,732 legacy buffer accesses versus 395
compact accesses (about 93% fewer), with elapsed time 7.96 versus 3.50 ms on visible
pages. After simulated retry churn touched 10% of rows, accesses were 5,732 versus
5,709 with 7,998 heap fetches; elapsed time was 5.73 versus 4.25 ms. The large
index-only benefit depends on visibility and does not prove a live memory reduction.
`num_nonnulls` itself checks nullness without detoasting text; precomputing the
boolean alone is not evidence of reduced TOAST I/O.

A 20,000-item representative-URI fixture used a four-buffer indexed lookup.
Neither fixture is representative capacity evidence.

Tests cover 4,480 source/status/field-mask combinations, legacy rows before and
after bounded backfill, direct writes, exact expiry equality, locked rows and
competing metadata writes, full legacy candidate parity, and interrupted concurrent
index recovery. Go rollup tests additionally cover inclusive window/exclusive expiry,
deleted source, lost derived state, postmaster identity invalidation, partition
changes, competing revisions, catch-up, and atomic acknowledgment failure. Destructive
recovery fixtures refuse hosted/non-disposable database URLs and require serial
package execution (`-p 1`). Simulated identity invalidation is not an actual restart.

## Isolated Lower-Memory Trial

The read-only full-snapshot collector accepts 8 → 6 → 4 decimal GB rounds while
retaining all identity, workload, latency/backlog, restart/recovery and OOM guards.
On measured 4,096-byte kernel pages the raw 6 GB cap is 5,999,996,928 bytes and 4 GB
is 3,999,997,952 bytes. Missing page metadata, GiB substitutions or one-byte
deviations are rejected. Safety unit tests are not capacity evidence.

Measure the workload changes at the existing limit first, including backfill cost
and sustained write churn. Use the same approved full snapshot, traffic mix, binary
hashes, CPU, pools and replicas in each isolated round. Compare per-request latency,
lease stability, publication freshness, ingestion/recovery and I/O pressure. Stop
at the first failed round. Include cold-start and actual restart recovery; restarting
PostgreSQL does not itself clear the filesystem cache.

Existing incremental rollups and the failed metadata scheduling experiment remain
disabled. Recovery correctness does not replace hot-key latency and combined CPU/WAL
performance gates. No lower hosted limit is validated by this patch.

PostgreSQL uses both shared buffers and operating-system cache. The goal is fewer
pages touched through selective access and exact projections. See the
[official resource documentation](https://www.postgresql.org/docs/18/runtime-config-resource.html)
and [statistics documentation](https://www.postgresql.org/docs/18/monitoring-stats.html).
