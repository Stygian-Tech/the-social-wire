# Operations Telemetry Overhead Benchmark

Run equivalent Gateway or AppView deployments with telemetry disabled and enabled, then compare the same authenticated route:

```sh
BASELINE_ORIGIN=https://baseline.example \
TELEMETRY_ORIGIN=https://telemetry.example \
BENCHMARK_PATH=/v1/appview/bootstrap-stream \
BENCHMARK_AUTHORIZATION='Bearer …' \
BENCHMARK_DPOP='…' \
bun scripts/benchmarks/operations-overhead.ts
```

Use the same database snapshot, worker cursor, region, machine size, request count, and concurrency for both runs. Repeat for bootstrap, entries, unread counts, and sidebar. For ingestion, run identical bounded Jetstream replay jobs against isolated database snapshots and compare the emitted `socialwire.ingestion.events_total` rate and commit-lag p95.

The command fails if throughput or p95 regresses by more than 5%. `OperationsTelemetryBufferTests` separately verifies that exporter failure cannot grow the in-process queue beyond its configured bound.

## Railway Usage Capture

Capture equivalent 24-hour or seven-day UTC windows using an already authenticated
Railway CLI. This issues a fixed read-only query; it includes deleted services and
groups raw CPU, memory, network transmit, disk, and backup usage by service and
environment IDs.

```sh
python3 scripts/benchmarks/capture_railway_usage.py \
  --project 19eba29f-9229-4f8d-8b3c-44cbb839d656 \
  --start 2026-09-05T00:00:00Z --end 2026-09-06T00:00:00Z \
  --output /tmp/tsw92-usage-20260905.json
```

Run after the requested interval ends. Windows must be positive, at most 31 days,
and use explicit UTC timestamps. The new output file has mode `0600` and records
the exact requested window, capture time, provider measurement identifiers and
unconverted values. Existing captures are never overwritten. GraphQL partial
errors, CLI failures, and invalid measurements fail the capture.

These values are provider usage measurements, not dollar costs or instantaneous
resource metrics. No CPU/time conversion is assumed, absent rows are not treated
as zero, and provider reporting may lag. Keep restore-drill service IDs separate
when comparing steady-state costs; bucket charges and any costs absent from this
API still need their own billing evidence. Tests use fake CLI responses:
`python3 -m unittest discover -s scripts/benchmarks/tests -p test_capture_railway_usage.py`.

## Synthetic Wire Write Replay

`fixtures/WireWriteAmplificationReplayTests.swift` measures the real Wire inbox
processor and embedded-metadata write paths. Copy the same fixture, unchanged,
into `services/wire-worker/Tests/WireWorkerTests/` in temporary worktrees checked
out at the exact baseline and candidate commit SHAs. Remove the temporary test
copies after the runs; keep the reusable fixture here.

Run each revision against a fresh, fully migrated disposable local database on an
otherwise idle PostgreSQL cluster. The URL must use a loopback host, an explicit
nonzero port other than `5432`, and a database name matching
`^tsw92_write_[a-f0-9]{12}$`. The only permitted URL query option is
`sslmode=disable`. The fixture rejects existing Wire data. Provisioning and
removing disposable databases belongs to the enclosing runner.

Set these three variables separately for each revision:

```sh
export WIRE_WRITE_REPLAY_DATABASE_URL='postgres://postgres:disposable-password@127.0.0.1:55495/tsw92_write_012345abcdef'
export WIRE_WRITE_REPLAY_OUTPUT='/tmp/wire-write-replay-baseline.json'
export WIRE_WRITE_REPLAY_REVISION='<exact 40-character lowercase commit SHA>'
timeout 600s swift test --package-path services/wire-worker \
  --filter WireWriteAmplificationReplayTests
```

Run from that revision's worktree. The output must be an absolute path that does
not already exist. Use `gtimeout` on macOS when GNU `timeout` is installed under
that name, or an equivalent runner that terminates the process after the bound.
The outer timeout covers compilation and stalled I/O; the fixture also checks a
120-second replay budget between operations.

The deterministic fixture runs 200 snapshot projections and 200 metadata seeds,
split into repeated identical timestamps and changing timestamps within one
hour. Initial and final live commits verify genuine activity: 202 inbox rows
must apply, actor activity counts both live commits, and the latest publication
signal replaces the earlier signal for the same source URI. Source fields and
exact observation/ranking timestamps remain checked; these real timestamp
changes intentionally still write. Cache expiry may extend by the approved extra
hour, and preserving an existing metadata retry deadline is an intentional
candidate-only behavior change.

Treat this as a synthetic shared-item hot-key comparison, not a Production
workload, memory benchmark, or savings estimate. WAL insertion-LSN deltas are
cluster-wide and include inbox bookkeeping and all actual processor side effects;
other writers invalidate the comparison. Tuple-change counts observe the item,
its AT-URI alias, and metadata row, not the separate URL alias or every WAL record.
Use equivalent fresh clusters and identical fixture bytes for paired results;
Production savings still require matched workload and billing windows.
