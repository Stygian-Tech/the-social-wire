# Wire Rollup Benchmark

`wire-rollup-benchmark.py` compares the actual aggregate SQL extracted from the Swift store with its incremental form. It requires Python 3, Docker, and an explicitly named disposable PostgreSQL 18 container. Container names must start with `tsw92-`; database names must start with `tsw92_`. Do not use a shared integration-test container or a hosted database.

Create a fresh local container without publishing a network port:

```sh
docker run --name tsw92-rollup-benchmark \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=tsw92_rollup_benchmark \
  -d postgres:18 \
  -c shared_buffers=128MB -c work_mem=4MB -c track_io_timing=on
```

Once PostgreSQL is ready, populate the minimal synthetic schema and compare queries:

```sh
python3 scripts/benchmarks/wire-rollup-benchmark.py setup \
  --container tsw92-rollup-benchmark --output /tmp/tsw92-rollup-results
python3 scripts/benchmarks/wire-rollup-benchmark.py query \
  --container tsw92-rollup-benchmark --output /tmp/tsw92-rollup-results \
  --restart-between-scenarios --incremental-jit-off
python3 scripts/benchmarks/wire-rollup-benchmark.py ingest \
  --container tsw92-rollup-benchmark --output /tmp/tsw92-rollup-results \
  --incremental-jit-off --combined-key-count 10000
```

Setup creates 600,000 signals spanning seven days, 10,000 canonical keys, and 20,000 feedback rows. The fixture uses partitioned unlogged signal tables, the relevant lookup indexes, unlogged feedback/rollups, and the actual scheduling migration. It intentionally omits unrelated production constraints and services. Setup fails if its tables already exist; it does not drop an existing database.

The query command measures the full oracle and empty, 1%, 50%, and 100% key sets. It saves exact SQL, source fingerprints, full JSON `EXPLAIN (ANALYZE, BUFFERS, WAL)` plans, execution times, and container CPU deltas. `--key-counts` and `--repetitions` permit bounded variations. `--incremental-jit-off` changes only the incremental transaction; the full oracle keeps the default JIT configuration. Run into distinct output directories when comparing variants.

The ingestion command alternates tracking disabled/enabled with eight clients performing 1,000 single-statement transactions each. It tests keys spread over 1,000 items and a single contended key, then repeats with an aggregate running concurrently. It records insertion p50/p95/p99, container CPU, WAL LSN deltas, and aggregate duration. `--combined-key-count` defaults to 100; use 10,000 to test dense recomputation. This command deletes only its synthetic `bench-` source rows between samples and truncates the disposable dirty queue.

## Interpretation limits

- This is a synthetic query and trigger benchmark, not a representative replay or acceptance test. It does not cover the complete publication/maintenance transaction, real ingestion batches, cleanup, authenticated user latency, queue age, or recovery throughput.
- A container restart clears PostgreSQL shared buffers. It does **not** clear the host filesystem cache; results must be described as restarted PostgreSQL buffers, not fully cold storage.
- Container CPU includes the benchmark's local `psql`/`pgbench` processes and inspection overhead. Other host activity can affect elapsed times. Compare repeated matched samples.
- The fixture identity sequence and reduced schema affect absolute WAL volume. WAL differences are a narrow trigger comparison, not a forecast of production WAL.
- Source fingerprints include both store files so changes to interpolated SQL fragments are visible. Compare only known source variants.
- Ingestion latency percentiles cover thousands of synthetic transactions. Five repeated aggregate measurements do not establish a reliable production p95.
- Passing these probes is insufficient to enable the production reader. Representative combined CPU/WAL, backlog, correctness, restart, and performance gates still apply.

## September 13, 2026 Synthetic Findings

On the fixture above, grouped feedback with transaction-local JIT disabled reduced
shared-buffer accesses by 98.9% for a 1% key set and by 20.8% for a dense key set.
Warm dense aggregate median execution was 691 ms versus 758 ms for the unchanged
oracle. These are query-work measurements, not percentages of memory saved.

The first incremental query crossed PostgreSQL's JIT optimization threshold:
compilation rose from about 23 ms to 287 ms. A query-local JIT override removed
that penalty. No global JIT, shared-buffer, or work-memory setting changed.

A single dirty row per canonical key introduced contention under eight concurrent
writers. Sixteen backend-PID shards reduced the repeated combined-workload CPU
median increase to approximately 2.1% for spread keys and 1.3% for one hot key.
However, some individual pairs exceeded 5%. Forcing all writers onto one shard
produced a 27.4% median CPU increase and insertion p95 around 0.346 ms versus
0.128 ms. Sharding bounds the amount of scheduling state; it does not guarantee
that writers never contend. The forced-collision result does not pass the CPU
gate.

Keep the feature disabled until representative replay validates the actual pool
and shard distribution, bursts, full maintenance transactions, and longer matched
CPU/WAL windows. Typical synthetic medians are insufficient to claim that every
performance gate has passed or that a lower Production memory limit is safe.

The CLI safety checks use a fake Docker executable and need no running database:

```sh
python3 -m unittest discover -s scripts/benchmarks/tests \
  -p test_wire_rollup_benchmark.py
```
