# Full-snapshot Railway memory trials

This companion **does not replace** `postgres_replay.py` or loosen its 256 MiB seed / 60-second restore guards. That tool remains a bounded real-archive pilot: two code variants, one anonymous Wire page every five seconds, no container memory measurement. Its synthetic ranking fixture and empty-schema replay are not Production capacity evidence.

`postgres_memory_trial.py` adds a read-only database/container probe, streaming stop gates, and repeatable evidence validation. It never changes Railway configuration, restores a snapshot, restarts a process, resets statistics, deletes data, or executes arbitrary SQL from configuration. The probe must execute **inside the explicitly named isolated Postgres container**, not a worker/runner cgroup. It requires matching Railway project, environment, service and volume IDs, the isolated `tsw92-*.railway.internal` hostname and an explicit `tsw92_memory_<12 hex digits>` database. Protected source IDs must include the actual Production and Development service/volume/environment IDs. Credentials are supplied by an environment-variable name and never emitted.

## Preparation and comparison order

1. An operator provisions an isolated Railway environment, Postgres service and volume, plus co-located isolated application services. Record actual IDs, CPU allocation, pool/replica limits, region, database version/settings and extension versions. Use separate application credentials and private endpoints; restored sessions/control state must not reconnect to normal workers or upstream mutation endpoints. Snapshot data stays private. No automatic preparation is performed by this script.
2. Restore the same approved **full** snapshot before **each** 16 → 12 → 8 GB round (decimal Railway limits), using the recovery procedure rather than the pilot's SQL seed loader. Verify the actual restored relation sizes/cardinalities against the source inventory. Keep all non-memory settings and application binary hashes unchanged. Do not reuse the database left after the preceding workload. Stop descent at the first failed round; the preceding passing level is the candidate for further QA, not automatic Production approval.
3. Write `memory-trial-snapshot.json` on the isolated mounted volume after restore verification: `{"dataset":"full_snapshot","snapshot_sha256":"<64 hex>","restored_bytes":<verified bytes>,"restore_epoch":"<unique restore ID>"}`. This is a reviewed operator attestation, **not cryptographic proof that a physical restore is correct**. `minimum_restore_bytes` must come from the reviewed source inventory, not a conveniently small fixture; the probe also checks actual database bytes. Preserve restore logs/manifests alongside evidence.
4. Set the memory limit externally for that round and copy its exact Railway `memoryBytes` value into `memory_limit_bytes`: **16 GB = 16,000,000,000 bytes**, **12 GB = 12,000,000,000 bytes**, **8 GB = 8,000,000,000 bytes**. Verify `memory.max` reports exactly that integer; do not convert these decimal limits to GiB. The collector refuses a mismatch. A Railway restart/OOM receipt from outside the database container is required across restart: `{"previous_container_epoch":<previous probe epoch>,"termination_reason":"operator_restart","oom_killed":false}`. Local counters alone cannot prove that the previous container did not die from OOM. Do not fabricate this receipt from a scheduled restart timestamp; verify the actual provider result and stop if unavailable.

## Concrete timing and inputs

Use `observation_seconds: 3600`, `sample_seconds: 5`, `restart_at_seconds: 1800`, `restart_grace_seconds: 120`. Run mixed workload from startup, burst from seconds 900–1205, request the controlled restart at second 1800, then continue recovery workload for at least 605 measured seconds and mixed load afterward. Continue sampling until **3600 seconds of valid observation excluding the restart gap** have accumulated; allow up to 3840 wall-clock seconds. The final actionable queue must be zero. Both queues are sampled with a 10001-row lower-bound cap; set `maximum_queue_rows` below that cap.

The same seeded, hashed **representative authenticated workload** must run in every round. Include ingestion, ranking, sidebar/bootstrap, pagination, detail reads, supported language feeds and authenticated viewer actions against isolated accounts. Preserve request mix, offered-rate schedule, archive segment hashes/bounds, corpus age treatment, worker admission/pool settings and random seed in the workload manifest. A driver interval supplies `load` on each probe record:

```
{"workload_sha256":"<64 hex>","binary_manifest_sha256":"<64 hex>",
 "seed":12345,"phase":"mixed|burst|recovery",
 "interval_start":<Unix seconds>,"interval_end":<Unix seconds>,
 "attempted":<interval requests>,"successful":<interval successes>,"p95_ms":<interval p95>}
```

The existing replay driver can provide real archive intake and ranking with fixed archive bounds, but its anonymous single-page reader is insufficient for this mixed load. **An authenticated mixed-load driver/trace and its baseline rate must be supplied and reviewed before running the trial.** The collector cannot turn synthetic samples, a mislabeled trace, or a short low-load interval into a capacity proof. Keep per-request latency evidence for final percentile comparisons; do not average interval p95s.

Each round configuration supplies:

- `target`: `project_id`, `environment_id`, `service_id`, `volume_id`, `host`, `database`.
- `protected_source_ids`: actual normal-service/volume/environment IDs, never empty.
- `database_url_environment`: for example `TSW92_MEMORY_DATABASE_URL`; optional `psql` binary.
- `memory_limit_bytes`: exactly `16000000000`, `12000000000` or `8000000000` as a JSON integer; `snapshot_sha256`, `workload_sha256`, `binary_manifest_sha256`, identical `seed`.
- The timing fields above.
- Positive reviewed stops: `minimum_free_bytes` (include backup/WAL/headroom reserve), `minimum_restore_bytes`, `maximum_queue_age_seconds`, `maximum_queue_rows` (<10001), `maximum_connections`, `maximum_p95_ms`. Set latency/queue limits from the measured 16 GB (16,000,000,000-byte) baseline and product SLOs **before** lower-memory rounds. No default thresholds imply capacity acceptance.

The legacy `memory_gib` key is rejected, including configurations that also supply `memory_limit_bytes`. Prepare newly reviewed round configurations; do not silently reinterpret old binary-limit evidence as a decimal Railway round. Probe, preflight and per-sample gates compare exact byte values, and the final summary records `memory_limit_bytes`. A cap differing by one byte, a binary 16 GiB cap (17,179,869,184 bytes), or an unlimited cgroup is a mismatch.

The memory field in the reviewed 16 GB round configuration is:

```json
{"memory_limit_bytes": 16000000000}
```

This is a configuration fragment, not a runnable round on its own. The 12 GB and 8 GB configurations use `12000000000` and `8000000000` respectively; all other comparable workload inputs remain unchanged.

## Collection and stop contract

On the isolated database service, an operator-run probe invocation is:

```sh
python3 /benchmark/postgres_memory_trial.py sample /benchmark/memory-16.json
```

A separately supervised isolated load launcher collects that JSON every five seconds, joins the matching interval's driver `load` object, and attaches the independent `restart_receipt` to the first recovered sample. It must stop its owned intake/load processes when the streaming validator exits nonzero, and retain the isolated database for diagnosis. The collector itself cannot stop independently launched services. Pipe joined JSONL through:

```sh
python3 scripts/benchmarks/postgres_memory_trial.py watch /benchmark/memory-16.json > /benchmark/evidence/memory-16.jsonl
```

The launcher must provide stdin; the command deliberately does not connect to Railway or launch a workload implicitly. Missing input, oversized/partial records, wrong identity, insufficient snapshot bytes, memory-limit drift, OOM, archive failure, excessive queue age/size, latency/errors, connections, headroom loss or an unexpected reset/restart rejects the round. Stop the load immediately on rejection; do not delete pending/leased rows to obtain a pass. Preserve failed evidence. The declared restart gap is excluded from WAL spans and observed duration; WAL is **not** billable upload volume. Interval database stats include temp-file counters and checkpoint/archive epochs; container evidence includes memory current, anon/file cache accounting and OOM events.

Revalidate the recorded file without hosted access:

```sh
python3 scripts/benchmarks/postgres_memory_trial.py validate /benchmark/memory-16.json --samples /benchmark/evidence/memory-16.jsonl
```

Repeat only after restoring the same snapshot with a new restore epoch and applying the next limit externally. Compare all three configurations/manifests for identical snapshot, workload, binaries, seed, CPU, pools, replicas and offered rates before comparing results. Do not combine WAL/reset epochs or include restore/restart downtime in observed workload time. A passing evidence gate still requires source-inventory review, authenticated QA, recovery verification, and the later 24-hour / seven-day cost comparison. Capture provider CPU/memory/network/volume/bucket usage separately with `capture_railway_usage.py`; extra Redis/worker costs must remain in the comparison.

Safety tests: `python3 -m unittest discover -s scripts/benchmarks/tests`. These fabricate telemetry to test rejection paths and are not load evidence.
