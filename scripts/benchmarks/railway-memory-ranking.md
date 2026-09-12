# Owned Coordinator ranking adapter

`railway_memory_ranking.py` implements the memory runner's existing `ranking` JSONL progress contract. It starts the reviewed **IndexingWorker** executable with `INDEXING_WORKER_ROLE=coordinator`, preserving the existing App View coordinator and Wire materializer lease supervisors and fenced publication transactions. It does not implement another ranker, invoke unfenced `WireWorker rank`, change the production runtime, or claim a passing memory trial. No hosted workload was run to validate this adapter.

Run it only through `postgres_memory_trial_runner.py` in a separately provisioned, verified `tsw92-*` Railway runner. Its local Coordinator writes only to the explicitly matched isolated database and Redis services. The provider adapter's canonical Development/Production exclusions, restored snapshot verification, live service/volume/private endpoint identity and current runner deployment checks run before the child starts. Redis also requires an independently verified service, deployment and private endpoint in that same isolated environment. No database or Redis credentials are inherited from the invoking shell; reviewed credentials come from an owner-only runtime file.

## Reviewed inputs

Add this object to the existing round configuration; placeholders are preparation guidance, not runnable trial evidence:

```json
{
  "ranking": {
    "binary": {"path": "/usr/local/bin/IndexingWorker", "sha256": "<reviewed real binary hash>"},
    "psql": "/usr/bin/psql",
    "runtime_environment_file": "/run/secrets/ranking-runtime.json",
    "runtime_environment_sha256": "<hash of exact private JSON bytes>",
    "source_generations": ["tsw92-replay-aaaaaaaaaaaa"],
    "supported_languages": ["und", "en"],
    "config_version": "wire-v10",
    "sample_seconds": 10,
    "maximum_stale_seconds": 720,
    "maximum_runtime_seconds": 5000,
    "redis_target": {
      "service_id": "<isolated Redis service UUID>",
      "host": "tsw92-redis.railway.internal",
      "port": 6379
    },
    "evidence_file": "/trial-output/round-13-ranking.jsonl"
  }
}
```

Replace `supported_languages` with the **complete reviewed inventory for the restored representative corpus**, including `und`. The two-language example is not a production inventory. The real worker derives up to twelve eligible locale buckets from candidates each cycle; the observer rejects unexpected languages and cannot count a cycle missing any reviewed language. Preserve that source behavior rather than forcing a different language selection for the benchmark.

Pin this executable under `runner.adapters.ranking` and in the existing binary manifest's complete `adapters` map. Add a `ranking` manifest object containing exactly `binary_sha256`, `runtime_environment_sha256`, and `evidence_module_sha256` (the SHA-256 of `memory_ranking_evidence.py`). Retain all existing provider/remote-probe hashes and other adapters. Recompute the whole `binary_manifest_sha256`. Build the real Coordinator from the reviewed application revision and record its build provenance with the trial; an executable name alone does not establish provenance.

The runtime file is a flat string-to-string JSON map, private to its owner and at most 64 KiB. It must contain the isolated `DATABASE_URL` and `REDIS_URL`, `APP_ENV=dev`, `ENABLE_THIN_APPVIEW=true`, `APPVIEW_CACHE_BACKEND=redis`, `WIRE_FEED_MODE=api` or `visible`, `WIRE_EXTERNAL_SIGNAL_MODE=off`, and `WIRE_LANGUAGE_BUCKET=und`. The ranking adapter calls the shared `trial_replay_receipts.scope(config)` validator: `source_generations` must equal the single `replay_receipts.source_generation` (`tsw92-replay-` plus twelve lowercase hex characters). Set both `WIRE_INBOX_SOURCE_GENERATIONS` and `JETSTREAM_SOURCE_GENERATION` to that exact source. Its private runtime file path and hash must also match `replay_receipts.runtime_environment_file` and `runtime_environment_sha256`. Match the real replay adapter's exact scopes so cleanup and recovery inspect the intended inbox records.

Copy reviewed candidate limits, generation/graph/cleanup cadence, retention, pool ceilings, lease timing and actor HMAC settings from the accepted baseline. The finite operational allowlist and `WIRE_*`/`THIN_APPVIEW_*` settings preserve their existing runtime parsing; hashing the file fixes those choices for matched comparisons. Production versus trial settings and any deliberately isolated upstream endpoints still require a reviewed inventory. The adapter does not fabricate a representative configuration, disable genuine recovery, or silently lower concurrency. Explicitly set runtime `PORT`, `INDEXING_APPVIEW_HEALTH_PORT`, and `INDEXING_WIRE_HEALTH_PORT`. The adapter requires all three to be valid and distinct from each other and from `replay.ingest_port` and `replay.drain_port`: five distinct ports on the shared runner. Coordinator binds its public and component health listeners to loopback through the existing runtime; this does not imply the separate Go intake supports loopback binding.

The shared private runtime may contain `JETSTREAM_API_KEY` for Go replay; ranking accepts this as an input-only key and removes it before constructing Coordinator or libpq environments. Only actual Railway project/environment/service/deployment IDs and PATH/LANG pass through from the runner. A unique per-process `HOSTNAME` supplies the existing lease owner's fallback; an unrelated inherited replica owner is stripped. Database URLs remain private process environment inputs to the real worker and libpq, never command arguments or progress output. Outbound Operations alert settings, loader injection variables, inherited Railway tokens and arbitrary process settings are not forwarded. The provider CLI uses its separately configured credential path as documented in `railway-memory-adapters.md`.

## Completion and bounds

One read-only observation runs serially every 10–30 seconds with a two-second PostgreSQL statement timeout, 500 ms lock timeout, two-second connect timeout and three-second local process deadline. It reads the two Coordinator leases and at most 2,049 generation records; more than 2,048 records rejects the observation rather than accepting truncated evidence. Output is capped at 2 MiB. Per-generation child existence uses the generation index; it does not recount every ranked item. No counters are reset, dashboard requests issued or database settings changed.

Cycle identity is the exact shared `generated_at` used by the real `WireWorkerCycle`. Count increases only when every reviewed language is visible with committed/superseded status, non-null commit marker, a valid serving/history relationship, positive ranked count, ranked children and unexpired retention. This relies on the application's atomic generation/items/feed-pointer publication transaction; it is not an independent reconciliation of every child row. The cycle must start after this process's observation baseline and its currently owned Wire lease acquisition. Both real Coordinator roles must be owned and unexpired. Foreign ownership, regressing fences, changed database identity, ambiguous language publications and unexpected algorithm/language inventories fail closed.

The existing schema writes `committed_at` from generation time. Therefore the receipt records **`first_observed_complete_at` from the database clock**, separately from `generated_at`; it never presents generation time as publication completion time. The private JSONL ledger preserves generation UUIDs, Wire fence and newly observed cycles. Stdout exposes the same bounded progress events, including monotonic cumulative `completed`; the existing runner can consume that field without a contract change. The ledger is newly created with mode 0600, capped at 16 MiB, and is never overwritten.

Missing language publication, absent authority or stale generations produce no new completions. No fresh complete all-language observation within the configured maximum of twelve minutes fails the adapter. Database unavailability produces an explicit unavailable event with the unchanged completion count, only within the existing restart grace and freshness deadlines while the real child remains alive. Lease reacquisition excludes incomplete work from an older ownership interval; it preserves previously observed completions. Any child exit fails immediately and is never automatically respawned or interpreted from free-text logs as a successful restart.

The outer runner creates the adapter's session/process group. Coordinator and observer subprocesses remain inside it. A separate watchdog detects parent loss and the configured lifetime, bounded to 15,000 seconds and at least the parent round plus restart grace plus 120 seconds. On cancellation or failure, the supervisor sends TERM only to its owned group, then KILL after one second, including itself; the parent runner retains its independent three-second forced cleanup. A killed supervisor is expected during parent-initiated teardown, and an early supervisor exit remains a failed trial. No remote Coordinator is launched and no process is located or terminated by name.

Coordinator CPU/memory belong to the isolated runner, not the PostgreSQL cgroup. Record those costs alongside Redis, replay workers and database costs. A complete trial still needs the real applied-replay adapter, authenticated signer/trace, source snapshot freshness and controlled restart evidence. This addition neither supplies those inputs nor relaxes the one-hour recovery, all-language freshness, OOM or throughput acceptance gates.

## Local validation

```sh
python3 -W error::ResourceWarning -m unittest discover -s scripts/benchmarks/tests
```

The optional SQL tests accept only database `tsw114_ranking_adapter` on `127.0.0.1:55414`; supply its URL privately through `RANKING_TEST_DATABASE_URL` and, if needed, the psql executable through `RANKING_TEST_PSQL`. They create and drop a unique schema in that database, use the actual migration table declarations, and check real transaction visibility and lock timeouts. Unit/process tests cover incomplete/stale/duplicate publications, changed identity/ownership, simulated restart/reacquisition, private input hashes, real shared replay-scope/config composition, early child exit, parent loss and stubborn descendant cleanup. These tests do not restart the shared local server, run the Coordinator workload or provide capacity evidence.
