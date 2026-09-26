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

## Paired Full Refresh Probe

The `paired` command measures the complete refresh SQL while eight clients insert
at a controlled arrival rate. It alternates off/on then on/off between matched
pairs. The selective arm claims the keys actually written during the trial,
uses transaction-local JIT off, processes batches of at most 1,000, and publishes
and acknowledges in the same repeatable-read transaction. A PL/pgSQL exception
block reproduces the Swift acknowledgment savepoint's 40001-only rollback.
The oracle keeps its existing isolation and JIT settings.

```sh
python3 scripts/benchmarks/wire-rollup-benchmark.py paired \
  --container tsw92-rollup-benchmark --output /tmp/tsw92-rollup-paired \
  --pairs 4 --duration-seconds 12 --transactions-per-second 1000
```

Run setup first; query output is not required. Use an idle host and a separate
output directory. Each trial rebuilds the disposable rollups and schedule, then
runs one refresh two seconds into sustained inserts. Initial rebuild and complete
refresh duration are separate fields; both include local Docker/psql startup.
Exact emitted SQL and source fingerprints are saved with per-trial p50/p95/p99 and pgbench output. Latency includes pgbench
schedule lag; compare each matched pair, and treat trials as the independent
observations rather than pooling every transaction into a claimed confidence
interval. A failed refresh fails the command instead of being omitted.

This fixes three limitations of the earlier `ingest` probe: subsecond samples,
fixed off-before-on ordering, and refreshing `item-*` keys while concurrent writers
only modified unrelated `bench-*` keys. The earlier probe remains available for
isolated trigger costs. Neither command simulates the whole application. The
paired probe excludes ranking, Swift transport and retries outside acknowledgment,
production foreign keys, and other services. It must not be presented as hosted
latency acceptance or used to bypass representative replay and the soak.

## Interpretation limits

- This is a synthetic query and trigger benchmark, not a representative replay or acceptance test. The legacy query/ingest commands do not cover the complete publication/maintenance transaction. No command covers real ingestion batches, cleanup, authenticated user latency, queue age, or recovery throughput.
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

## September 26, 2026 Full Refresh Findings

A controlled 1,000 transaction/second probe exposed a failure hidden by the
aggregate-only measurements: concurrent updates to claimed dirty hints caused
repeatable-read acknowledgment to fail all three whole-refresh retries. The
acknowledgment savepoint now retains those hints and allows the exact snapshot to
publish; deterministic PostgreSQL integration tests check subsequent catch-up and
full-oracle parity.

Four counterbalanced pairs per workload then completed every refresh:

| Synthetic workload | Paired geometric mean ingest p95 change | Individual paired changes | Median complete refresh, off → on |
| --- | ---: | --- | ---: |
| 1,000 spread keys | +0.73% | −1.73% to +3.29% | 975.7 → 99.9 ms |
| One hot key | +3.79% | −6.96% to +14.58% | 961.7 → 78.3 ms |

Each arm ran for 12 seconds with eight clients; latency includes scheduling lag.
Initial selective rebuilds took 1.61–2.01 seconds versus 0.99–1.01 seconds for the
oracle and are separate from steady-state sparse refreshes. Timed trials ran
without the other agent's local replay/build workload.

The hot-key result still does **not** establish the 10% latency gate. There are only
four independent pairs, one exceeds 10%, and a normal-log-ratio t interval is wide
(approximately −9.4% to +18.9%). Treat that interval as exploratory, not a robust
production confidence bound. The complete application needs representative replay
and hosted measurements; the faster refresh does not justify overlooking the
remaining tail-latency uncertainty.
