# Supplemental memory-step acceptance gates

`memory_step_acceptance.py` validates a local JSON evidence document. It does not collect observations, contact Railway/Postgres, run load, change limits, restart services, or verify the contents of referenced artifacts. No hosted trial has been performed by adding this tool. Unit fixtures are synthetic safety tests, never capacity evidence.

This shares the page-alignment rule from the adjacent `postgres_memory_trial.py` (and its adjacent `postgres_replay.py` dependency); keep those reviewed files together. It complements `postgres_memory_trial.py` and its owned-process runner. Keep their identity, restore, source inventory, headroom, workload, connection, archive, throughput and restart gates. This tool does not replace `Round`, relax its immediate stop limits, or make its stricter queue/restart rules disappear. The supplemental queue rule below expresses the new step criterion; the existing runner can still stop a trial earlier.

Run after collecting evidence:

```sh
python3 scripts/benchmarks/memory_step_acceptance.py /private/evidence/memory-step.json
```

The command prints one JSON assessment and exits zero only when the submitted supplemental gates pass. Invalid JSON (including duplicate keys), nonfinite values, missing files and missing or unavailable evidence exit nonzero. It reads at most 32 MiB characters and follows no artifact references. The operator must retain the actual artifacts separately.

## Meaning of the result

| Field | Meaning |
|---|---|
| `gates_status` | `passed` or `blocked` for the submitted values and supplemental rules. |
| `readiness` | `ready_for_operator_review` or `blocked`; never deployment authorization or service health. |
| `overall_trial_status` | Always `not_proven_by_this_validator`. Existing runner results, representative workload/inventory review, authenticated QA and recovery verification are still required. |
| `evidence_proof` | Always `submitted_values_only_references_not_independently_verified`. An `available` flag, hash or reference is not independent proof that a collector or reviewer did the work. |

The result includes the window and recorded assessment timestamps. Freshness is evaluated at the explicitly supplied `assessed_at`, not at the current wall clock. An archived passing report remains a statement about that historical window; it does not establish current readiness. The collector/operator must record the real assessment time and supply new observations for a new assessment.

No result means a lower memory cap has been deployed or savings achieved. Production reduction remains sequential: 13, 12, 11, then 10 decimal GB, stopping at a failed step and retaining the last passing level. This validator assesses one step; it does not prove preceding steps or the final seven-day total-cost comparison.

## Evidence contract, version 1

All timestamps are finite Unix seconds. All counters are nonnegative JSON integers; booleans, numeric strings and binary-unit approximations are rejected. `available` must be the literal `true`, with a nonempty `evidence_ref`, on each sample, latency summary, burst, restart receipt and discovery report. References identify collected private artifacts; do not put credentials or raw request bodies in this document.

The top-level object contains `schema_version: 1`, `config`, `started_at`, `ended_at`, `assessed_at`, `baseline`, `latency`, `samples`, `bursts`, and `restart`. Development also requires `discovery_rebuild`. Production requires the complete previously collected `development_evidence` document for the same step, not merely a label saying it passed.

`config` contains:

- `stage`: `development` or `production`.
- `memory_limit_bytes`: exactly `13000000000`, `12000000000`, `11000000000` or `10000000000`. Every requested sample cap must match exactly; its separate raw cgroup cap must match the verified page floor. The retired `memory_gib` key is rejected.
- `supported_languages`: the complete configured language list; no default language is inferred. Each minute must include every language's latest **committed, complete, currently served** generation, not a generation that merely started processing.
- `queue_names`: the complete reviewed actionable-queue inventory, including Wire and AppView ingestion. Name each queue consistently; exclude terminal history, while preserving all durable recovery state.
- `latency_groups`: the complete reviewed user-facing request groups. Keep matching request mix and offered rates in the reviewed workload; do not select a conveniently fast subset.
- `comparison`: exactly `workload_sha256`, `non_memory_settings_sha256` and `binary_manifest_sha256`, each a lowercase SHA-256. Non-memory settings include CPU, pools, replicas, admission, languages and offered-load schedules. Lower-cap trials and the 16 GB baseline must use the same fingerprints.
- `maximum_baseline_age_seconds`: a reviewed positive age limit no greater than seven days. Both the baseline and a Production step's Development prerequisite must be within this limit when the step starts. A reused stale baseline is not accepted silently.

`baseline` and `latency` contain `available`, `evidence_ref`, `comparison`, `started_at`, `ended_at`, `method: "raw_request_percentile"`, `p95_ms`, and `request_counts`. The latter two maps contain every configured latency group with positive values/counts. Baseline additionally has `memory_limit_bytes: 16000000000` and covers at least one prior hour. New baseline evidence includes raw `memory_max` and measured `page_size_bytes`; legacy exact 16 GB baseline evidence without those fields remains accepted without inventing a page measurement. Candidate latency covers the exact assessed window. Percentiles come from the matching raw request samples, including successful authentication handshake time, never an average of interval p95 values. A group's p95 at exactly 110% of baseline passes; anything greater blocks. The tool checks the declared values/method, not the referenced raw requests.

## Minute observations

Each sample contains:

| Field | Source/semantics |
|---|---|
| `started_at`, `ended_at` | A complete 60-second observation interval. Intervals must partition the window without duplication, overlap or unaccounted gaps. |
| `observed_at`, `collected_at` | Actual source observation and collection times. Observation falls within its minute; collection cannot precede it, be over 60 seconds later, or follow assessment. Never relabel an old cached observation with a new time. |
| `available`, `evidence_ref` | All required measurements are available; reference the source ledger/log. Unavailable is not zero. |
| `memory_limit_bytes` | Requested Railway cap, as an exact decimal-byte integer matching the step configuration. |
| `memory_max`, `page_size_bytes` | Raw target cgroup cap and target `SC_PAGE_SIZE` measurement. Require the exact page floor of the requested cap; the currently verified Railway page size is 4096 bytes. A one-byte drift, unknown/missing page size, rounded-up value or GiB cap fails. Preserve both fields unchanged across the step. |
| `oom_events`, `oom_kills` | Event **deltas during this minute**, including external provider termination evidence across container changes. Both must be zero. |
| `avoidable_coordinator_restarts` | Event delta from the reviewed Coordinator lifecycle ledger. Must be zero. A deliberate isolated database restart is recorded separately, not reclassified as an avoidable Coordinator restart. |
| `lease_loss_events` | Final authority-loss events, deduplicated across lifecycle log messages. Successfully recovered transient renewal attempts are not separate authority losses. Two or more final losses anywhere in the step block it. |
| `generations` | Map of each supported language to the served complete generation's publication timestamp. Missing, future-dated, or older than 720 seconds at the end of the minute blocks; the final values must also be fresh when assessed. |
| `actionable_queue_age_seconds` | Map of every configured queue to its actual oldest actionable age. Explicit zero means observed empty. Ages greater than 60 seconds for three consecutive valid minutes on the same queue block; exactly 60 resets that queue's streak. |

Assess within 60 seconds of the window ending. Development needs at least 3,600 **measured** seconds; Production needs at least 86,400 measured seconds at the exact successful step. Minute evidence remains required throughout; two endpoint observations cannot establish a soak.

## Burst, restart and recovery evidence

Development must contain at least one `bursts` entry. Each has availability/reference fields, `started_at`, `ended_at`, `drained_at`, and `remaining_actionable_rows: 0`. Drainage is measured from burst end and must finish within 300 seconds, inside the observed window. Exactly 300 seconds passes. A restart cannot bridge or conceal a burst's drainage interval. Production declares an explicit list (possibly empty for a natural steady-state day); every reported burst obeys the same gate. Its prerequisite Development document supplies the required controlled burst.

Development requires one `restart` receipt with availability/reference fields, `requested_at`, `database_ready_at`, `observation_paused_at`, `observation_resumed_at`, `termination_reason: "operator_restart"`, and `oom_killed: false`. These come from independently collected provider/process evidence. The source pause encloses the requested restart and queryability time, occurs inside the window and is at most one hour. This upper bound does **not** override the existing runner's shorter configured restart-grace stop. The pause must correspond exactly to the sole gap between minute intervals. It is excluded from measured duration and resets queue streaks; it cannot hide a second outage. No missing samples outside that explicit receipt gap are allowed.

`discovery_rebuild` contains availability/reference fields, `started_at`, `ended_at`, `complete: true`, and `durable_state_verified: true`. Start timing at or before the restart request, never after the expensive portion of recovery. Completion must follow that restart and occur within 3,600 seconds and the observation window. Exactly one hour passes. Preserve evidence for source corpus and durable user/recovery state; an empty cache or HTTP 200 alone cannot substantiate these flags. Production only needs its own rebuild report if it also records a controlled restart; its matching Development prerequisite always includes the controlled restart and recovery report.

For Production, the embedded Development document must independently pass these supplemental checks, precede the Production window, be recent, and match memory cap, fingerprints, languages, queues and latency groups. This verifies consistency of submitted prerequisites; it does not authenticate their provenance.

Tests are deterministic and use no hosted calls:

```sh
python3 -m unittest discover -s scripts/benchmarks/tests -p test_memory_step_acceptance.py
```

Requested caps remain unchanged: a 13 GB request is 13,000,000,000 bytes while its verified 4096-byte-page cgroup cap is 12,999,999,488 bytes. Assessment output preserves `memory_limit_bytes`, `memory_max`, and `page_size_bytes`; it does not independently verify the submitted page measurement or its source artifact.
