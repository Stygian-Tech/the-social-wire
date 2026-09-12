# Isolated replay acknowledgement receipts

`trial_replay_receipts.py` provides the install/sample building blocks for the memory runner's real replay adapter. **It does not launch Go intake or Swift drain.** Do not configure its one-shot sample command as `runner.adapters.replay`. The owned launcher, reviewed archive/rate manifest, process supervision and private runtime environment remain required before running a trial.

The existing Go `snapshot_complete` checkpoint proves a sealed `(after_seq,before_seq]` archive traversal. It is not an application count. Swift drain telemetry is an interval accumulator and can miss acknowledged work when another concurrent task fails; inbox terminal rows expire after 300 seconds. Neither is used for cumulative throughput evidence here.

The installer creates the logged `tsw92_trial_receipts.applied` table and two trial-only triggers in an explicitly verified isolated database. It refuses an existing receipt namespace or any existing checkpoint/inbox/recommendation/dependency state for the chosen fresh source. The installer locks those tables briefly before checking freshness and installing; both lock and statement waits are bounded. There is **no Production migration, automatic historical backfill, reset or cleanup operation**.

Receipts use the exact stable key `(environment,source_generation,seq)`:

- Inbox transitions to `applied` with a non-null `applied_at` are recorded in their own transaction, including bulk passive-reference acknowledgements.
- Recommendation journal transitions to `resolved` or `deleted` record the same key, including a deferred event resolved after its inbox envelope expires.
- `ON CONFLICT DO NOTHING` prevents duplicate credit from journal plus inbox acknowledgement, retry or re-staging after source loss. Rollback removes the receipt with the mutation; a lost COMMIT response still leaves the committed receipt queryable.
- Dead letters, pending/retry/leased/deferred work, superseded records and merely downloaded records do not add credit. An applied passive no-op does count, matching current Wire acknowledgement semantics. **This is unique committed acknowledged-event throughput, not changed-content throughput.** A receipt retained through a crash does not prove that lost unlogged projections were rebuilt; discovery recovery remains a separate gate.

Configure `replay_receipts` with `module_sha256`, `environment: "dev"`, a fresh `source_generation` matching `tsw92-replay-<12 lowercase hex>`, exact integer `after_seq`/`before_seq`, `maximum_receipts`, `maximum_receipt_bytes`, `semantics: "unique_committed_acknowledged_events"`, and `instrumentation_in_both_rounds: true`. Provide an absolute owner-only JSON string-map `runtime_environment_file` and its `runtime_environment_sha256`. It must contain the exact isolated `DATABASE_URL`, `APP_ENV=dev`, and matching `WIRE_INBOX_SOURCE_GENERATIONS`. Optional `psql` identifies the installed client.

The maximum sequence span is ten million and must be no greater than `maximum_receipts`; the primary key and sequence CHECK therefore impose a hard row bound even if every sequence matches. This conservative limit counts possible sequences, not estimated filtered matches. A wider archive requires separately reviewed bounds; never split/repeat a range to manufacture fresh throughput. `maximum_receipt_bytes` is an explicit observed stop cap of at most two billion bytes. The sampler rejects cap breaches, disabled triggers, changed source bounds, or non-logged receipt relations. The launcher must treat every rejected/failed sample as a stop condition and stop owned intake/drain children.

Install **before** starting the dedicated source, using the same live provider/restore/private-origin verification as the existing Railway adapters:

```sh
python3 scripts/benchmarks/trial_replay_receipts.py install /private/config.json
python3 scripts/benchmarks/trial_replay_receipts.py sample /private/config.json
```

`sample` returns `completed`, `snapshot_complete`, `drain_complete`, and `receipt_bytes` from one database statement snapshot. Exact drainage checks the chosen source's inbox, pending/conflicted recommendation journal, and unresolved dependency recovery, including future retries. A sealed checkpoint with the exact lower/upper/sealed bounds is independently required. Neither empty queues nor a positive count substitutes for it. The runner requires a recent final receipt with both booleans true. Exhaustion before the final throughput window fails representativeness; an archive still incomplete at the fixed observation boundary fails, with no automatic extended tail. The authorized database restart resets the partial throughput window; cumulative receipts remain visible but neither outage time nor previously observed work earns new-window credit.

This instrumentation adds logged rows, an index and acknowledgement-trigger writes to an otherwise largely unlogged path. Count sampling also scans the bounded receipt ledger under a five-second statement timeout. Include its exact module/hash, range, cadence and bounds in both baseline and candidate manifests, report receipt bytes plus total measured WAL/CPU/database time, and measure the overhead separately before treating results as capacity evidence. **Do not label these instrumented figures as unmodified Production performance or subtract an assumed overhead.** No hosted installation or capacity trial has been performed by adding this code.

Validation uses actual PostgreSQL transactions on disposable local tables, covering rollback, terminal deletion, bulk acknowledgement, deferred journal resolution, duplicate concurrent commits, fresh-source refusal, exact completion and disabled instrumentation. `TSW_RECEIPT_TEST_ADMIN_URL` enables these tests on loopback PostgreSQL18; each test suite creates and drops its own generated database. An optional `TSW_RECEIPT_RESTART_CONTAINER` accepts only a separately owned, labelled `tsw92-receipt-test-<12 hex>` Docker container mapped to that exact loopback port and tests a real clean restart. The default suite does not restart a shared PostgreSQL service.
