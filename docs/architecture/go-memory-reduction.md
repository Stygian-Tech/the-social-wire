# Go Memory Reduction (TSW-154)

## Production Baseline

Read-only Railway `mcp__railway__get_service_metrics` calls on October 7, 2026,
approximately 21:41 UTC, used `hoursBack: 1` and the default sample rate
(61 samples). Coordinator was queried about one minute before the other services.
The API returned a rolling preceding-hour window without explicit start/end timestamps.

Project: `19eba29f-9229-4f8d-8b3c-44cbb839d656`.
Production environment: `523aeabb-2d5f-4f8c-892d-2aa69dfa8390`.

These are Railway service-level memory values in the provider's reported GB units,
not Go heap measurements or per-replica measurements. Production was not modified.

| Service | Average GB | Maximum GB |
| --- | ---: | ---: |
| Postgres | 7.9599 | 7.9996 |
| Projection Pool | 0.5045 | 0.6381 |
| Coordinator | 0.1652 | 0.2261 |
| Ingress | 0.0429 | 0.0490 |
| Operations | 0.0280 | Not recorded here |
| AppView | 0.0271 | Not recorded here |
| Gateway | 0.0217 | Not recorded here |
| Wire Corpus | 0.0034 | Not recorded here |

Postgres dominates this snapshot. Its reported footprint cannot establish whether
memory is PostgreSQL working memory, shared buffers, filesystem cache, or connection
backends. Application Go changes alone do not establish a reduction in database memory.

Coordinator variable names included `POSTGRES_MAX_CONNECTIONS` and
`WIRE_POSTGRES_MAX_CONNECTIONS`; their values were redacted. Its variable names did not
include `GOMEMLIMIT` or `GOGC`. This observation applies only to the inspected environment.

## Implemented Retention Fixes

`topicreadcore/finance_search.go` copies at most 50 selected results into a correctly
sized slice before caching. Previously a broad query could keep the backing array and
pointer-bearing tail of up to 50,000 matching instruments reachable through 50 results.
Search order, provider policy, response limit, and cache lifetime remain unchanged.

Both `telemetrycore/buffer.go` and `appviewworkercore/telemetry_buffer.go` clear consumed
queue slots after copying the in-flight batch and release the backing allocation when
the queue drains. Previously exported maps and event/span attributes could remain
reachable behind a shortened slice. Pending batches, in-flight capacity, retry order,
and loss accounting retain their existing behavior.

## Local Evidence

Benchmarks ran on Apple M4 Max, darwin/arm64, Go 1.27.1, with unchanged fixtures before
and after the fixes. Retention counters measure referenced backing-array bytes or
consumed payload string bytes; they are not process RSS or collected heap measurements.

| Fixture | Before | After | Allocation Cost |
| --- | ---: | ---: | --- |
| Finance: select 50 of 50,000 instruments | 9,600,000 backing bytes | 9,600 backing bytes | One allocation, approximately 9,733 B/op |
| Shared telemetry: drain 64 distinct 1 KiB payloads | 65,536 consumed payload bytes | 0 | Unchanged: 135,768 B/op, 331 allocs/op |
| Worker telemetry: same drained burst | 65,536 consumed payload bytes | 0 | Unchanged: 130,088 B/op, 331 allocs/op |

The Finance backing-array fixture decreases by 99.9%; this is a pathological broad-query
case, not a prediction of live memory savings. It excludes separately allocated strings,
optional metadata, and nested slices. Telemetry metrics exclude map/queue overhead.

Regression tests first failed on the original behavior, then passed after the fixes.
They cover Finance empty/small/large result sets and independent storage, partial and
complete telemetry drains, and preservation of payloads still waiting for export.
Existing tests cover retries, in-flight capacity, and failure/loss accounting.

Validation completed:

- `go test ./...` in `packages/go`.
- `go test -race ./topicreadcore ./telemetrycore ./appviewworkercore`.
- `go vet ./...` in `packages/go`.
- Both retention benchmarks in all three changed packages.

Local HTTP/Redis fixtures required loopback-listener permission. PostgreSQL integration
cases requiring `SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL` were skipped because no disposable
database was configured. These checks do not establish deployment or live savings.

## Next Experiments

1. Capture Go live heap, heap goal, total runtime memory, goroutine count, allocation
   rate, and GC CPU alongside service memory and request/ingestion throughput. Sample
   per instance with fixed metric cardinality; keep profiling access internal. Compare
   matched traffic windows and the same replica count after deployment.
2. Measure the Wire worker SQL pool and PostgreSQL connection backends. The code defaults
   to up to 12 open connections, retaining all idle connections for five minutes.
   Trial a configurable idle cap of one or two and a shorter idle lifetime in Development;
   compare pool waits, transaction latency, reconnect costs, and ingestion lag. Leave
   maximum-open concurrency unchanged until saturation evidence supports a change.
3. Profile corpus payload-cache JSON/date conversion before optimizing it. Its repeated
   typed/untyped serialization preserves Swift cache-date compatibility and required
   field validation; replacements must retain those contracts.
4. Consider per-service `GOMEMLIMIT` or `GOGC` budgets only after heap and GC profiling.
   Reserve headroom for runtime-external memory and check CPU/latency and ingestion lag.
   A Go soft memory limit cannot fix a retained live object graph. Follow the
   [official Go GC guide](https://go.dev/doc/gc-guide) for the memory/CPU tradeoff.

No pool, GC, provider-policy, or hosted service settings changed in this patch.
