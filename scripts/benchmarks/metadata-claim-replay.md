# Metadata Claim Replay

`metadata_claim_replay.py` compares the existing priority claim with two experimental
plans while preserving its exact `last_signal_at DESC NULLS LAST`, `retry_after`,
`canonical_key` order and the general lane's 25% reservation. Neither experimental
query is enabled in the application.

The runner requires an explicitly disposable PostgreSQL database on a loopback
address whose name starts with `tsw114_`. It replaces only the
`tsw114_metadata_replay` schema inside that database. It rejects remote hosts,
application database names, URL options and fragments. It does not reset counters.
Supply `TSW_METADATA_REPLAY_DATABASE_URL` privately, then run:

```sh
python3 scripts/benchmarks/metadata_claim_replay.py \
  --rows 100000 --repeats 3 --batches 128 64 32 8 \
  --output /tmp/metadata-claim-replay.json
python3 -m unittest discover -s scripts/benchmarks/tests -p 'test_metadata_claim_replay.py'
```

The fixture includes the columns and indexes relevant to claiming, with four
distributions: sparse due rows (1%), dense due rows (50%), equal signal timestamps
(10% due), and mostly null signal timestamps (1% due). Retry times deliberately
order against the canonical key. One-seventh of items have a known language and
must use the general lane. Each sample claims the same total of 128 rows, either
in one batch or multiple smaller batches, then rolls the transaction back. Query
order rotates between repetitions. Reported shared buffers count accesses, not
unique pages or allocated memory. PostgreSQL runs each sample with a 120-second
statement timeout.

For every distribution the runner also holds a leading priority row locked in a
second connection. All three variants must skip it and claim the same six other
rows. Claim sets must agree across variants at each batch size; different batch
sizes may interleave priority and general work differently. `UPDATE RETURNING`
row order is deliberately not treated as guaranteed.

## September 12, 2026 Local Results

PostgreSQL 18, 100,000 items and cache rows per distribution, three repetitions.
Values below are median summed database execution milliseconds for 128 claims,
including both priority and general SQL. All exact-set and locked-row checks
passed.

| Distribution | Batch | Existing | Cache-Driven Lateral | Materialized Due Cache |
|---|---:|---:|---:|---:|
| Sparse | 128 | 15.76 | 5.27 | 5.93 |
| Sparse | 8 | 223.87 | 42.24 | 46.51 |
| Dense | 128 | 2.58 | 133.44 | 64.51 |
| Dense | 8 | 9.74 | 1,954.45 | 984.53 |
| Tied Signals | 128 | 20.76 | 27.17 | 30.34 |
| Tied Signals | 8 | 306.53 | 398.24 | 439.69 |
| Mostly Null Signals | 128 | 15.82 | 5.52 | 6.18 |
| Mostly Null Signals | 8 | 211.69 | 44.46 | 49.54 |

The sparse existing plan changed from a hash join and sort at batch 128 to an
incremental sort with nested index probes at batch 8. Shared-buffer accesses per
128 claims rose from approximately 4,720 to 502,442. The experimental plans helped
sparse data but regressed dense data substantially and spilled to temporary files;
the existing dense plan did not spill. Intermediate batch sizes also increased
total claim work: existing sparse batches 64 and 32 took 34.48 and 51.65 ms;
existing tied batches 64 and 32 took 39.73 and 78.30 ms.

Keep the existing query and batch quota while fixing queued-lease renewal and
completion ownership. These results reject an unconditional forced join order
and a blanket reduction to eight-row claims. A future query change must improve
both sparse and dense cases without changing scheduling fairness.

This is a synthetic, local, mostly warm-cache replay. It uses literal SQL inputs
and simplified tables, not a full Production corpus or the application's prepared
statement lifecycle. It excludes HTTP fetching, repair sweeps, concurrent ingestion,
network overhead and full queue dynamics. Rollbacks still cause database work.
The results are not Production latency, memory, WAL savings or billing acceptance.
The local JSON report records timings, shared/temporary buffers, WAL bytes and
plan node types; Production adoption still requires representative application
replay and staged verification.
