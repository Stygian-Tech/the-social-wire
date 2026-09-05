# Isolated PostgreSQL replay comparison

`postgres_replay.py` runs the **baseline then candidate sequentially** on one benchmark host and one dedicated PostgreSQL server. Each variant gets a newly created random database restored from the same SQL seed. Only its own database is removed after every child has stopped. No existing database, checkpoint, counter or replay budget is reset. Processes use identical pool/admission limits, source identity, archive bounds, HMAC material and reader rate; ranking cadence, generation retention, binaries and explicitly listed candidate migrations are the measured changes.

This is a real recent archive pilot, not a synthetic performance fixture or proof of Production peak capacity. The example range was verified September 5, 2026: US-West `(25539389975,25541831042]`, segment `seg_00000005pf.jss`, checksum `13d9bc719f9bc318`, witnessed 00:21:24–02:14:19 UTC, 2,291,485 raw events and 238,296,854 compressed bytes. Provider planning with the repository's complete Wire collection list selected that exact segment. Raw archive events are not the same as admitted Wire rows. Refresh the range if it becomes stale; use archive metadata, never sequence arithmetic, to identify time boundaries.

## Prepare once

1. Create a temporary Railway benchmark runner and **dedicated** PostgreSQL target in the same region, with fixed CPU/RAM/disk limits for both variants. Source Development currently has the legacy `sfo` volume region; verify actual resource placement rather than assuming `us-west2`. Do not attach the normal Development volume or alter its signed Production Corpus Edge route. Use a target service hostname beginning `tsw92-` and ending `.railway.internal`. Local smoke tests may use a nondefault loopback port. Normal Railway Postgres and public database origins are rejected.
2. Build the exact revisions in the example configuration using the same Swift/Go toolchains and release mode. Use fresh exported source trees (`git archive <full-SHA>`), not the dirty working tree. Build `services/jetstream-ingest` (`go build -trimpath ./cmd/jetstream-ingest`), `services/wire-worker` (`swift build -c release --product WireWorker`) and `services/appview` (`swift build -c release --product AppView`). Put the binaries on the same runner with their required Swift/runtime libraries, Python 3 and `psql`. No repository paths are implicitly rebuilt by the benchmark.
3. Create a bounded baseline SQL seed with the **baseline migration schema**, including baseline indexes; it may contain approved Development-only public ranking inputs if both variants use the identical bytes. Prefer the baseline migration chain in an otherwise empty disposable database, then `pg_dump --no-owner --no-privileges` with a matching client to retain the migration ledger and initial rows. Never use Production raw signals, actor hashes or viewer state. The seed limit is 256 MiB and seed restore timeout 60 seconds; this tool does not replace a physical restore drill. Keep candidate migrations separate so index removal is part of its treatment. Use the same PostgreSQL version/settings/extension preload for both variants.
4. Ensure the target has no other client workloads. Record volume free space before starting and leave at least 16 GiB headroom above the configured database+WAL cap. The cap sums all database sizes and the WAL directory; it does not account for every filesystem file, backup staging or OS cache. Monitor Railway's actual volume during the run as well. Do not run backup/restore drills on this target concurrently.
5. Copy `postgres-replay.example.json`, change binary/seed paths and exact candidate SHA as needed, and retain the same common limits for both variants. Explicit treatment fields remain visible in the manifest. Inject `TSW92_BENCH_ADMIN_URL` and `TSW92_ARCHIVE_API_KEY` from Railway references; do not put credential values in JSON or shell history. API keys are sent only to the fixed US-West archive host. Configuration is saved in evidence, so it must remain secret-free.

When the common seed includes actor hashes projected from public posts, use the
same isolated actor key for seeding and both measured variants. Set the optional
configuration field `actor_hmac_secret_environment` to the name of a private
environment variable (for example `TSW92_REPLAY_ACTOR_HMAC_SECRET`), containing at
least 32 UTF-8 bytes after trimming. Only the variable name is saved in evidence.
Missing, blank, or short configured keys fail before the run; omitting the field
preserves the default fresh random key shared by both variants. Never reuse a
Production actor key. A seed created with a different key cannot measure correct
actor deduplication across its boundary.

## Run

```sh
python3 scripts/benchmarks/postgres_replay.py /benchmark/config.json \
  --output /benchmark/evidence/run-20260905
```

The runner revalidates archive names/checksums and both sealed bounds before each variant, creates/loads its own database, then starts private AppView, Wire drain, Wire rank, and bounded ingestion as separate child processes. AppView uses `APP_ENV=prod` **only against the guarded disposable database**, because the real Development application intentionally requires remote Corpus Edge. The remaining processes use `APP_ENV=dev` and the isolated source generation. This exercises the existing Production local-read branch without weakening Development's configuration guard or using Production credentials. Child HTTP ports 18081–18084 must be free; no public endpoint is needed.

The script polls SQL and one private first-page read at the configured interval, using the existing signed anonymous Gateway-to-AppView contract and a per-run temporary trust secret. Both variants run for the same configured `observation_seconds` from process startup; the safety deadline is separate. Passing acceptance requires the exact durable `snapshot_complete` marker, successful ingester exit, zero actionable rows, no dead letters, at least two distinct nonempty active generations and the configured successful local-read count. Successful reads must match the local active generation and report ranked/nondegraded content. Empty/sparse archives can complete transport correctly while failing load acceptance; quality gates are not relaxed. A five-second sampling interval is 0.2 requests/second, a correctness/load pilot rather than a peak concurrency test.

It aborts on child failure, runtime safety deadline, counter reset, database+WAL cap or dead letters. Unresolved references and insufficient useful local reads produce failed acceptance at the fixed observation boundary; the next variant still runs, so both observations remain available. A completed comparison with any failed acceptance exits nonzero. Pending dependencies are preserved throughout the observation and are never terminalized to manufacture success. SIGTERM/interrupt stop children before database removal. If child shutdown cannot be confirmed, it records the retained owned database and does not drop it. Temporary runner/service removal remains an explicit operator step after saving evidence.

## Evidence and acceptance

Each variant records binary and seed hashes, treatment migration hashes, samples, private child logs and a result. Samples include WAL/reset epoch, database/WAL bytes, bounded actionable/dead-letter counts (10001 means a lower bound), oldest actionable age, checkpoint progress, inserted/updated/deleted table counters, active generation/duration and private read latency. Derive ingestion rate from `wire_ingestion_inbox.n_tup_ins` counter deltas divided by elapsed time; source sequence subtraction is not an event count. Use the samples for latency distributions, excluding failed/empty/remote responses and reporting exclusions separately. Keep child logs private; they can include public source identifiers.

The first and last counter samples define the measured WAL interval. Candidate duration diagnostics are expected; the baseline binary may not export them, so its generation cadence comes from timestamps/logs. Capture `scripts/capture-postgres-cost.sql` and Railway CPU/RAM/volume independently around each run; the script does not claim container CPU/memory attribution. `pg_stat_statements` comparisons must retain its own reset/deallocation metadata as well as WAL/database reset epochs.

Results also include exact partition-spanning signal totals and counts by kind,
captured before the timed observation and after all children stop. These bounded
read-only queries avoid treating partition-parent statistics as total signal
cardinality. A failed final count marks acceptance failed while preserving cleanup.

Sequential runs avoid competing worker CPU/disk, but external label/metadata cache state, archive throttling and wall-clock ranking age can still differ. Record those limits, repeat in reversed order if they materially affect results, and do not call unmatched samples equivalent. This pilot does not replace authenticated web/iOS bootstrap/pagination/expiry QA, a full-day live input soak, seven-day retained-state evaluation or the backup restore gate. Those require the dedicated isolated AppView/Gateway test path; normal Development's remote Wire responses are not local database evidence.

Run harness safety tests with:

```sh
python3 -m unittest discover -s scripts/benchmarks/tests
```

## Separate synthetic 5,000-candidate capacity trial

When the real archive has too few eligible stories to exercise generation writes,
use `fixtures/WireRankingCapacityTests.swift` as a **separate synthetic capacity
experiment**. It invents 5,000 `.invalid` stories and five distinct baseline
sharers per story. The real rollup refresh, candidate SQL, ranker, generation
commit and edition projection run against PostgreSQL; a predefined synthetic
allow-label snapshot replaces external moderation, and no HTTP enrichment
runtime starts. This does not establish real popularity, production distribution,
ingestion throughput, request latency or scheduler savings.

Use the same baseline schema seed as the replay on a fresh, otherwise idle
dedicated target. Each variant needs a separate empty database named
`tsw92_bench_<12 lowercase hex digits>`; apply the candidate's two listed
migrations only to its database. For the reviewed revisions, baseline is
`b90cb13184c85673490769646714270c12e789fe` and candidate is
`bda2c3af046ec2ab5703f9e888e1ca5ae5dd9e77`. Keep fixture bytes, PostgreSQL settings,
machine resources and toolchain identical. The fixture itself creates all
synthetic input rows and uses the same fixed input timestamp and three measured
cycles for both variants.

Copy and compile the fixture in **both exported trees before measuring either**:

```sh
for capacity_variant in baseline candidate; do
  capacity_package="/benchmark/exports/$capacity_variant/services/wire-worker"
  cp scripts/benchmarks/fixtures/WireRankingCapacityTests.swift \
    "$capacity_package/Tests/WireWorkerTests/WireRankingCapacityTests.swift"
  env -u WIRE_CAPACITY_DATABASE_URL swift test -c release \
    --package-path "$capacity_package" --filter WireRankingCapacityTests
done
```

For each variant sequentially, inject `WIRE_CAPACITY_DATABASE_URL` privately,
set `WIRE_CAPACITY_REVISION` to that exact exported commit, and set
`WIRE_CAPACITY_OUTPUT` to a new absolute JSON path. Set `WIRE_CAPACITY_PACKAGE`
to the exported worker package path. Run the prebuilt test with an outer timeout:

```sh
python3 - <<'PY'
import os
import signal
import subprocess
process = subprocess.Popen([
    "swift", "test", "-c", "release", "--skip-build",
    "--package-path", os.environ["WIRE_CAPACITY_PACKAGE"],
    "--filter", "WireRankingCapacityTests",
], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=150))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit("Capacity trial exceeded its process deadline")
PY
```

The driver also enforces a 120-second cancellation deadline and a 2 GiB
database-plus-WAL-directory cap. Success requires 5,000 loaded candidates,
ranked rows and rollups, and 25,000 signal events in each cycle. JSON records each
cycle's duration, counter/reset epochs, insertion LSNs, sizes and cardinalities;
the first cycle is cold. WAL is cluster-wide, so concurrent clients invalidate
attribution. After every test process has stopped, the enclosing operator or
harness removes only the database it created. See `fixtures/README.md` for scope
and cleanup details.
