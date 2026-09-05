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
