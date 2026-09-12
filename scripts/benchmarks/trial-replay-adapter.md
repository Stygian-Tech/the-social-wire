# Real isolated replay adapter

`trial_replay_adapter.py` is the long-lived `runner.adapters.replay` executable. It starts the existing compiled `jetstream-ingest` and `WireWorker` executables inside the verified isolated runner. It does not generate records, run synthetic SQL publication loops, or substitute downloaded/staged counts for acknowledgements. Its only progress output is the committed receipt sampler described in `trial-replay-receipts.md`.

The adapter verifies the live provider/restore/private-origin identity first. Go's existing health listener binds all interfaces; the wrapper does not invent a loopback setting. It requires the dedicated runner to have no Railway-generated domain, custom domain or TCP proxy, verified from live provider metadata before launch and every60 seconds; a changed or unavailable exposure check stops the trial. Swift and Coordinator use their supported loopback settings. The wrapper checks the real US-West archive's `planSnapshot` response against the reviewed segment names/checksums and exact sealed lower/upper range, installs the fresh trial-only receipt schema, then starts Swift drain and Go intake. Archive-plan redirects, proxies, oversized responses, changed segments, incomplete bounds and pagination fail closed. API keys stay in the owner-only runtime file and the Go environment; they are not passed to Swift or written into evidence.

Configure `runner.adapters.replay.path` to the absolute executable script and pin its SHA-256. Also configure `replay.module_sha256` to that hash. The existing binary manifest must include `workers.replay_ingest` and `workers.replay_drain` with the exact corresponding binary SHA-256 values; `replay.ingest` and `replay.drain` are `{path,sha256}` executable specifications. Keep both baseline/candidate worker hashes and all intentional treatment differences visible in the reviewed manifest.

The shared owner-only runtime file is selected by `replay_receipts.runtime_environment_file` and its hash. It must supply string values for:

- `DATABASE_URL`, `APP_ENV=dev`, `WIRE_ACTOR_HMAC_SECRET`, and `JETSTREAM_API_KEY`.
- `WIRE_INBOX_SOURCE_GENERATIONS` and `JETSTREAM_SOURCE_GENERATION`, both exactly the single fresh receipt source `tsw92-replay-<12 lowercase hex>`.
- Explicit reviewed `WIRE_POSTGRES_MAX_CONNECTIONS`, `WIRE_INBOX_BATCH_SIZE`, `WIRE_INBOX_CONCURRENCY`, and `WIRE_INBOX_IDLE_MILLISECONDS`.
- Explicit distinct `PORT`, `INDEXING_APPVIEW_HEALTH_PORT`, and `INDEXING_WIRE_HEALTH_PORT` for the ranking Coordinator in the shared runtime. Together with `replay.ingest_port` and `replay.drain_port`, all five listeners must have different port numbers. Each adapter overrides only its own children's actual supported port settings.
- Explicit `true`/`false` values for `WIRE_DEFERRED_RECOMMENDATIONS_ENABLED` and `WIRE_DEPENDENCY_HYDRATION_ENABLED`. Keep these aligned with the ranking Coordinator; enabling/disabling dependency work merely to empty the queue is not representative.

The adapter forwards only the worker's required keys plus actual Railway project/environment/service/deployment IDs, PATH and LANG. It does not inherit live ingestion flags, provider credentials, copy-source database URLs or remote Production feed configuration. Swift uses the actual `drain` role in shadow mode; no ranking process is duplicated. Go's legacy single Wire lane uses the existing fixed bounds, `JETSTREAM_REPLAY_SNAPSHOT_ONLY=true`, one segment stripe, one download worker, three download attempts and `JETSTREAM_EXIT_AFTER_SNAPSHOT=false`. Once its sealed range completes, the real Go process parks until shutdown. No live tail can open. The Go database pool remains its current hardcoded eight open/four idle connections; this adapter does not claim it is configurable.

Additional required `replay` settings:

| Field | Meaning |
| --- | --- |
| `archive_host` | Exactly `https://jetstream.us-west.bsky.network`. |
| `archive_segments`, `collections` | Exact reviewed segment name/checksum pairs and collection inventory. |
| `reviewed_matching_events`, `source_evidence` | Matching-event count from the reviewed archive and its evidence reference. This inventory is an input requiring review, not proof created by the adapter. |
| `admission_rate_per_second`, `admission_burst`, `batch_size` | Existing Go token-bucket admission settings. The burst cannot exceed the batch. The estimated paced duration must cover the observation through its final throughput window and be able to finish before the fixed end. Actual receipt throughput and final completion still must pass. |
| `maximum_inbox_rows`, `maximum_database_bytes` | Existing Go admission safety bounds. Inbox cap cannot exceed the runner's queue stop cap. |
| `incident_bytes`, `daily_bytes` | Existing replay-download budgets; daily must be at least incident. |
| `sample_seconds` | Receipt sampling interval, no longer than the runner's interval. Sampling queries still have the receipt module's five-second SQL timeout. |
| `maximum_unavailable_seconds` | Bounded SQL-observation grace, no longer than the runner's authorized restart grace. No fabricated progress is emitted during a failed query. |
| `maximum_runtime_seconds` | Absolute process deadline covering observation + restart grace +120s, at most15,000s. TERM/INT/ALRM bypass database retry handling. |
| `ingest_port`, `drain_port` | Distinct explicit local health ports, avoiding the Coordinator and reader processes. |
| `evidence_file` | Absolute new owner-only JSONL output for worker hashes/start/exit state, real receipt progress and unavailable/recovered samples. Raw worker logs and credentials are not copied. |

The script must be launched by the existing runner as its own session/process-group leader. Both binaries inherit that group; neither is detached or restarted by this wrapper. A signal, deadline, lost runner parent, invalid receipt or child exit stops intake first, retires the known children, then kills the complete owned group, including any surviving descendants. The runner's own group kill remains the independent backstop. The adapter never drops the database, clears pending work, resets checkpoints or uninstalls the receipt evidence.

**Restart acceptance is still a live gate.** Work stays active during the requested database restart. The wrapper can tolerate a bounded period of unavailable receipt queries only while both real workers remain alive. Go can exit when database lease renewal fails; any such exit fails this trial, with no automatic respawn or inferred success based on timing/free-text logs. A passing active-work restart/recovery test therefore remains unproven until observed; adding the adapter does not make that gate pass. If a reviewed restart policy is added later, it needs independently evidenced cause/window classification and bounded retries without quiescing the workload.

The finite archive is never repeated or extended to manufacture throughput. Premature exhaustion fails the runner's representativeness check; remaining unscanned archive or unresolved source/dependency work at the fixed observation boundary fails final acceptance. All receipt instrumentation and query costs remain included in both rounds, with the growth and overhead caveats from the receipt documentation. Reviewed matching counts, correct scope and successful offline tests alone do not establish a representative hour.

Validation covers pinned executables/runtime files, exact source bounds, no inherited live flags or credentials, real archive-plan contract fixtures, child exit rejection and actual process/descendant retirement on cancellation and an absolute deadline during a blocked query. Existing Go configuration/admission/bounded snapshot tests are also run. These are safety and contract tests, not a hosted archive replay or memory capacity result.
