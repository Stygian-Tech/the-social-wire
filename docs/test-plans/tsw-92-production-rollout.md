# TSW-92 Production Rollout Evidence

This follow-up records release validation after PR #479 reached Development at
`26f9dbf7cff7349bc5438230e48c790df3d5a652`. Code promotion is complete; optimization
activation and full rollout acceptance remain separate.
The earlier implementation report is a historical snapshot, not the current
deployment checklist. TSW-94 tracks telemetry acceptance.

## September 26 Production Activation

PR #483 promoted the code to `main` as
`92a0cb5bbdbc5c78d5d5cd28aa95a2273c6d829e` at 23:01:42 UTC after required CI
passed. All 16 affected Production deployments succeeded. Migrator
`438fca0e-0618-423b-ba41-cdb202774494` committed both new migrations, bringing
the schema to 81 receipts; all eight consolidated replicas passed the schema
gate before starting. This does not close authenticated or recovery acceptance.

The user subsequently authorized advancing the remaining activation stages and
selected external-card-first with a stable fallback for TSW-131. That source
fix and full replay validation are in progress. Compact admission and selective
aggregation remain disabled until their respective measurements pass.

Production telemetry catch-up was enabled at 23:47:39 UTC. Ops deployment
`70f32482-6e74-40ba-a7e3-b8c83d33a2a3` succeeded at the same release revision and
returned readiness 200 with the flag enabled. Its 23:48:19 startup round deleted
1,468 rows in three calls / 1,038 ms and reached zero-delete sleep. At 23:49:12,
the bounded expired-event sample was 23, expired metrics were absent, no sessions
were blocked, and the SSE earliest cursor had advanced from 2,212,987 to
2,214,421. No expired protected records existed in these samples; authenticated
SSE resume and live ten-call continuation remain unexercised. The next hourly
round is due around September 27 at 00:48 UTC. Raw provider usage baselines end
23:47:39 UTC in `/tmp/tsw92-production-telemetry-prestage-{24h,7d}-20260926.json`.
Relation-file sizes are not expected to shrink immediately after deletion.

The first legacy handoff stopped Jetstream V2 Ingest deployment
`fa21d717-9ec3-4fc2-a37a-1597cb1871a3` at 23:49:37 UTC. Ingress already held the
matching AppView intake lease at fence 1413. Post-stop checkpoints advanced
26,365,085,318 → 26,365,102,351 → 26,365,183,128 over more than four lease windows,
with unchanged owner and live renewal. Production auto-deploy is disabled only
for that retained legacy service; Development auto-deploy remains enabled.
Manual snapshot rollback, service configuration and source remain available.
Removing an idle contender does not prove a controller failover or projector
throughput equivalence. Memory/replay caps, source generations, cursors and
pending work remain unchanged.

## PR #480 Development Release

All 20 CI jobs, including `CI — Required`, passed for
`dac1aa837aa241781dfe22cf763a99ca5d1ce5d0` (run `36264453852`). PR #480 merged
September 26 at 19:31:22 UTC as `43f0f24edd9fe9e7be77d7a88bfe857873b28cd0`.
Migrator `96f706ac-91b5-4ca6-87be-1dfbf2a43573` succeeded, with migration
`20260926190000` recorded at 19:32:12.342589 UTC and the final function verified.

The configured migrator service reference did not enforce startup ordering:
App View started at 19:31:42 UTC and Ingress was ready at 19:32:05 UTC, before
migration completion. Railway excludes GitHub-push deployments from reference
ordering. This backward-compatible migration caused no observed startup failure,
but an explicit required-schema startup barrier is needed before relying on this
gate. Do not treat the reference variable alone as ordering evidence.

The follow-up adds a read-only startup check to all seven main-database consumer
images. It checks all 81 packaged migration receipts before executing the
application, with a 90-second deadline and no retained connection. Local
validation passed 153 top-level Go race tests (196 including subtests, zero
skips), `go vet`, 44 focused deployment/CI tests, and the Railway TypeScript
configuration check. Both the ingress image and shared Swift gate builder built;
container checks confirmed missing-schema blocking, committed-schema dispatch,
and SIGTERM cancellation in 0.083 seconds. Required PR CI and hosted gate
verification remain pending. Consolidated live watch paths also need scoped
Development reconciliation after merge.

The repaired Development telemetry canary began at 19:34:16 UTC. Ops deployment
`4b9eca1e-ef99-413d-8464-c6234690f89f` succeeded at the merge revision, with
`OPERATIONS_RETENTION_CATCHUP_ENABLED=true`. Its first cleanup round at 19:34:33
deleted 1,963 rows in three calls, taking 1,342 ms and reaching a zero-delete
result (`backlog_pending=false`). No cleanup query remained active at 19:36:24;
the expired change-event sample was 91 and the SSE watermark advanced. Relation
bytes remained unchanged, as expected. Verify the next hourly cycle around
20:34 UTC before claiming sustained idle/catch-up behavior.

The precise pre-stage usage windows end September 26 at 19:34:16 UTC, immediately
before canary activation. The 24-hour and seven-day baselines are saved in
`/tmp/tsw92-telemetry-repaired-prestage-24h-20260926.json` and
`/tmp/tsw92-telemetry-repaired-prestage-7d-20260926.json`. These supersede the
initial 19:35-minute-boundary capture, which included the first canary minute.
This canary does not start the whole-release soak: compact/selective admission,
authenticated acceptance, recovery resolution and service handoff remain gated.

## September 26 Development Baseline

- All affected backend deployments reached `SUCCESS`. App View's failed Railway
  snapshot build was replaced by `1cca76dd-8621-45b8-9ef3-58f34a92d3f7`; direct
  App View and Gateway readiness passed. Required PR CI passed.
- Connection inspection found only `Projection-Pool:projection-pool-appview` and
  `Projection-Pool:wire-drain`, with no wrapper pool. Coordinator retains its
  separate authority pool. Ingress minute metrics report maximum 8, idle 1 and
  no waits in idle samples; idle samples do not establish throughput parity.
- The Development publication lane has no likes, reposts or follows. It cannot
  independently validate engagement payload savings or selective aggregation.
- Legacy AppView intake, Charybdis and the dedicated Wire drain remain deployed.
  Source/filter equivalence is verified; takeover, throughput and complete
  replacement coverage still require live acceptance. No service was deleted.
- Database rollup tracking and the Coordinator selective reader remain off.
  Compact admission also remains off pending performance validation.

## Telemetry Stage

Development Ops `OPERATIONS_RETENTION_CATCHUP_ENABLED=true` was set on September
26 at 18:41:56 UTC. Deployment `5992f3e1-b893-423b-a6d2-3746eab8ef30` reached
`SUCCESS` and started at 18:42:11 UTC. The canary exposed expensive selection of
the last expired change events, so the flag was restored to `false` at 18:46:32
UTC. Rollback deployment `41d975d4-49c6-4b72-970f-9f544e8a0e30` reached `SUCCESS`.
This aborted canary does not count as a soak. Production remains unchanged.

Immediately before activation, `operations_change_events` occupied
5,409,456,128 relation bytes with about 3.34 million estimated rows; the bounded
expired-row sample returned 1,001, a lower bound rather than a full count.
`operations_metric_rollups` occupied 1,578,393,600 bytes and its expired-row sample
was zero. Existing expiry indexes are valid. Retention periods and protected
records are unchanged. Deletion may free reusable space without shrinking files.

The original cursor-ordered selector scanned retained history through the primary
key and filtered expiration. A two-second read-only selector probe timed out.
Materializing expired cursors through the existing expiry index before applying
the same cursor ordering completed in 211.763 ms with 55 expired rows. This
preserves which cursors a batch removes and how its watermark advances. It does
not claim the complete cleanup function takes 212 ms or bound the expired index
range to 1,000 reads. Deletions remain bounded at 1,000 per table per call.

Review added a dense-expiry fast path before that fallback: inspect at most four
times the requested batch size in cursor order, and skip the expiry-range scan
when that prefix supplies a full exact batch. The final read-only Development
probe completed in 433.145 ms, reading 4,000 prefix candidates and 127 expired
candidates. This measures selection only, not the complete cleanup function.

The matched pre-stage usage window is September 25 18:42 through September 26
18:42 UTC. Machine-local raw evidence is
`/tmp/tsw92-telemetry-baseline-24h-20260926.json`; compare it with the same-length
post-stage window by service and environment, including Redis and workers.
Restart both comparison windows when the repaired stage is activated.

## Serving Acceptance

Public Development Wire reads returned 30 stories, but `degraded=true`. The
shared Production corpus published a new ranked generation during inspection;
its recovery health still has unfinished archive replay for the September 8
epochs of `wire-global-v8-prod-external-live-v1` and
`wire-global-v8-prod-publication-live-tail-v1`. Publication baselines completed.
Recovery records and source cursors were not changed. Readiness and successful
public responses do not satisfy recovery or authenticated acceptance.

A bounded follow-up identified the unfinished conditions more precisely:

- The external source is `paused_budget`, with 17,184,737,949 durable replay bytes
  downloaded. Its staged sequence is 25,324,864,414 against a sealed sequence of
  25,470,663,514. The checkpoint last changed September 23 at 00:00:05 UTC.
- The publication source is live and beyond its sealed sequence, but has 27
  `malformed_event` dead letters, one `unresolved_subject` retry (1,255 attempts),
  and 134 pending rows. The retry and oldest pending rows date to September 26
  at 08:01:59 UTC. These records require diagnosis and normal recovery handling;
  clearing flags or deleting queued records would conceal the problem.
- Authenticated acceptance is waiting at the test account's Bluesky password
  screen in Chrome. No authenticated bootstrap or Circle result is claimed.

## Follow-up Fixes and Local Evidence

- Compact admission now avoids re-encoding already minimal normalized records,
  decodes JSON once per lookup, and reuses per-event subject membership keys.
  Numeric and malformed subject semantics remain covered by PostgreSQL parity.
  A 12,000-event public Jetstream capture, with synthetic relevance assignments,
  admitted exactly 3,397 events in both paths and preserved replay checkpoints
  and duplicate behavior. Boundary payload plus lookup bytes decreased 58.62%
  under that fixture's relevance mix; this is not a production savings estimate.
  Counterbalanced StageBatch p95 medians before the final malformed-UTF-8
  compatibility guard were 7.402 ms original and
  8.003 ms compact (+8.11%). Individual pairs ranged from -12.5% to +15.1%;
  fresh-only medians increased 11.3%. The complete latency gate remains open.
  The final guard retains the former raw-JSON behavior for malformed UTF-8;
  nine PostgreSQL cases confirm rejection of retained invalid bytes and the
  existing treatment of discarded fields. Go race tests against PostgreSQL,
  vet and build passed again after that correction.
- Selective refresh now contains only dirty-hint acknowledgment in a savepoint.
  A concurrent committed hint revision can produce SQLSTATE `40001` at that
  step even with `SKIP LOCKED`. Deferring acknowledgment keeps all hints for
  another refresh while atomically publishing the current exact snapshot.
  Other failures retain whole-transaction rollback/retry behavior. A controlled
  concurrent-write test proves publication excludes the later write, preserves
  its hint, and incorporates it on the next refresh with full-oracle parity.
- The repaired full-transaction benchmark ran 16 counterbalanced trials at
  1,000 synthetic transactions per second. Median refresh duration changed from
  975.7 to 99.9 ms for spread writes and 961.7 to 78.3 ms for popular-key writes.
  Ingest p95 paired geometric means changed by +0.73% and +3.79%, respectively.
  Popular-key individual pairs ranged from -6.96% to +14.58%; the small sample
  does not establish the required 10% latency bound. Ranking and real worker
  processing remain outside this synthetic benchmark.
  All 393 Wire tests passed; benchmark tooling ran 172 tests with 15 optional
  skips and no failures.
- The telemetry migration retains cursor-ordered deletion and atomic SSE
  watermarks. A bounded cursor prefix serves dense expired batches; an expiry
  index fallback handles sparse and empty tails without scanning all retained
  history. Both paths use the same statement snapshot. Focused PostgreSQL
  tests cover original-function parity, protected records, environment
  isolation, transactional rollback, repeat installation, and sparse/empty
  retained-history tails. Runtime SQL timeouts and retention remain unchanged.
  Six focused tests passed, including a 60,000-row dense fixture whose fallback
  never executes and whose candidate work stays at 4,000 rows for a 1,000-row
  deletion. All 81 migrations applied from an empty disposable
  PostgreSQL database, followed by a successful idempotent repeat.
- The complete spec suite passed 135 tests with 38 environment-dependent skips.
  Its process-cleanup subprocess tests require process inspection permissions;
  the sandbox-only run could not execute `ps`, and the permitted rerun passed.

## Release Gates Still Required

### Captured Stage-to-Worker Replay

The September 26 follow-up used the real Go Wire preparation/staging path and
Swift `PostgresWireInboxProcessor` in isolated local databases. The 12,000-event
capture produced 10,892 projectable events and 2,289 identically staged records
under deterministic synthetic alias/follow relevance. Four final off/on/on/off
drains applied all 2,289 records in 22.94–23.57 seconds, with no actual runtime
errors or ready/retry/leased residue. One intentional shutdown cancellation was
recorded separately. Worker apply p95 changes were +3.23% and +2.53% in the two
paired comparisons. This does not establish the ingress-only or hosted latency
gate, nor test concurrent staging, ranking, or representative Production load.

Full downstream projection parity remains unresolved. Across eight drains, ten
unchanged multi-URL posts selected alternative canonical destinations; even two
baseline runs disagreed. `allStrings` dictionary iteration feeds first-URL
selection nondeterministically. TSW-131 tracks this existing bug separately.
Actor/follow/account/version-fence facts and inbox outcomes matched. Do not omit
the differing posts to declare the full parity gate passed. The temporary test
file was removed; bounded evidence and the harness remain under `/tmp`.

### Outstanding Acceptance

- Counterbalanced compact-admission replay with exact envelope/admission parity,
  original versus accepted payload bytes, and no more than 10% p95 regression.
- Full selective-refresh transactions under concurrent signal writes, including
  acknowledgment, expiry, initial rebuild, maintenance and restart recovery;
  exact full-oracle parity and at least 80% sparse-read reduction.
- Authenticated bootstrap, unread state, Circle participants and fresh Wire
  generations. Gateway `ingestion_completeness=unknown` is not acceptance.
- Bounded telemetry catch-up progress, protected history and SSE resume behavior,
  stable query pressure, no new lease failures and no worsening actionable age.
- Individual fenced legacy-service handoffs, rollback checks and a 24-hour
  Development soak after the final accepted stage. The telemetry stage's start
  alone does not start the whole-release soak.
- Required CI, reviewed promotion through `main`, exact-revision migration and
  deployment verification, Production acceptance and matched cost comparisons.
