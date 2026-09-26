# Indexing service consolidation rollout

## TSW-92 staged completion

The September 26 inventory found both the consolidated and compatibility fleets
running. Preserve current lane identities and settings from `.railway/railway.ts`;
the original cutover examples below are historical and must not narrow current
generation scope to V1–V7 or restart the expired Production west replay canary.

Ship the code with compact ingestion, selective rollups, and telemetry catch-up
disabled. In Development, validate the following stages independently before
advancing. Record exact revisions, deployment IDs, flags, checkpoint/lease evidence,
pool counts, actionable queue age, authenticated latency, and workload counters in
TSW-92; link telemetry evidence to TSW-94.

1. **Connection ownership:** verify Projection has no wrapper pool, both component
   readiness probes pass, and Coordinator retains two authority connections plus
   its lazy diagnostic connection. Ingress uses per-lane maximum-open 8,
   maximum-idle 1, idle-timeout 60 seconds. Compare component-qualified
   `application_name` counts and Go pool waits; Swift's pinned pool exposes no
   public utilization callback, so use existing bounded database observations.
2. **Compact admission:** enable `JETSTREAM_WIRE_PUBLICATIONWEST_COMPACT_INGEST_ENABLED`
   in Development after tests and representative passive-signal replay pass.
   Publication-only live traffic cannot establish passive-signal savings; measure
   a representative isolated replay as well. Production later uses the matching
   external/publication lane flags. Rejected like/repost payloads must not cross
   the database boundary, while checkpoints, follows and deletes remain exact.
3. **Selective aggregation:** follow the existing incremental trial in
   `postgres-cost-reduction.md`. Enable tracking through
   `wire_set_signal_rollup_tracking(true)` with bounded lock/statement timeouts,
   then set `WIRE_SIGNAL_ROLLUP_INCREMENTAL_ENABLED=true` on Coordinator. Require
   the initial full refresh, exact oracle parity and at least 80% fewer sparse
   aggregation buffer accesses. Dirty hints, expiry scheduling, restart recovery,
   full maintenance cost and popular-key contention must pass too. A synthetic
   query benchmark alone is insufficient.
4. **Telemetry:** enable `OPERATIONS_RETENTION_CATCHUP_ENABLED=true` on Ops.
   Verify 1,000-row/table batches, at most ten calls per round, one-second pacing
   while work remains, hourly sleep only after a zero-delete result, and capped
   5/10/20/40/60-second error backoff. Preserve retention, audit/recovery exclusions
   and SSE earliest-available cursor updates. Deletion frees reusable space; it
   does not imply immediate file shrinkage.

Keep flags reflected in source after each accepted stage. Complete representative
replay and a 24-hour Development soak before Production promotion. Require no
new lease failures or worsening actionable backlog, no greater than 10% p95
authenticated latency regression, and lower measured connection, payload, and
aggregation work. Compare total database/Redis/worker costs over matched 24-hour
and seven-day windows; keep RAM, cadence, backup policy and retention unchanged.

For each environment, hand off legacy intake one service at a time with unchanged
source generation/filter/checkpoint domain/lease name. Retire dedicated drains
incrementally only after Projection covers their full scope and demonstrates
equivalent throughput. Production's `The Wire Worker Production` is a **drain**,
not a second ranker. Retire Charybdis only after projection, RSS, backfill,
retention and recovery have verified replacements. Keep two Coordinator replicas
and test token-incrementing failover. Keep stopped compatibility services
deployable through the soak; do not delete services, reset cursors, discard
pending claims or re-seed generations.

Rollback only the failed stage. Disable compact flags to restore the original
payload/admission path. Disable both incremental controls to remove tracking
overhead and restore full aggregation. Disable retention catch-up to restore
hourly scheduling. For service rollback, stop the replacement singleton before
restoring its compatibility worker; preserve the source/claim state.

Tracking changes acquire the same fail-fast parent lock as selective refreshes.
If maintenance or an active refresh owns that lock, retry the tracking change
after it finishes and verify `tracking_enabled` in `wire_signal_rollup_control`;
a failed enable/disable call does not change the previous tracking state.

This runbook replaces the separate AppView/Wire intake, projection, ranking, enrichment, and cleanup deployments with Ingress Controller, Projection Pool, and Coordinator. Execute Development first. Production requires a separate explicit promotion approval after the Development soak gates pass.

## Preconditions

1. `CI — Required` is green for the exact revision.
2. Database Migrator has applied `20260830190000_add_fenced_role_leases.sql` successfully.
3. Record current service replica counts, source generations, lease owners, inbox counts/ages, dead letters, latest AppView projection heartbeat, latest Wire generation, and direct feed results.
4. Confirm all new database consumers reference `DATABASE_MIGRATOR_SERVICE_ID=${{Database Migrator.RAILWAY_SERVICE_ID}}` and the same private Postgres service.
5. Keep old services deployed but do not allow an old unfenced singleton and its Coordinator replacement to run the same job concurrently.

## Service variables

### Ingress Controller

Apply the `Ingress Controller` resource from `/.railway/railway.ts`. It defines two replicas and preserves the existing shared `APP_ENV`, `DATABASE_URL`, Jetstream API key, and database-migrator reference. Enable both lanes:

```text
JETSTREAM_APPVIEW_ENABLED=true
JETSTREAM_WIRE_ENABLED=true
```

Move each old lane's settings to its namespaced equivalents (`JETSTREAM_APPVIEW_*` and `JETSTREAM_WIRE_*`). Preserve source generation, cursor bounds, collections, scope policy, admission controls, and leader lease names exactly during the first cutover.

Production has two Wire cursor domains. `JETSTREAM_WIRE_LANES=external,publication`
loads `JETSTREAM_WIRE_EXTERNAL_*` and `JETSTREAM_WIRE_PUBLICATION_*` as separate
supervised lanes. Do not collapse their US West/full-filter and US East/publication-filter
identities or compare their sequence numbers as though they share a cursor domain.

### Projection Pool

Apply the `Projection Pool` resource from `/.railway/railway.ts` and:

```text
INDEXING_WORKER_ROLE=projection
ENABLE_THIN_APPVIEW=true
```

Carry forward the AppView durable-inbox and Wire drain variables. Start with the current total drain capacity, then reduce replicas only after actionable inbox age remains within the existing SLO under peak load.

### Coordinator

Apply the `Coordinator` resource from `/.railway/railway.ts`, two replicas, and:

```text
INDEXING_WORKER_ROLE=coordinator
ENABLE_THIN_APPVIEW=true
```

Carry forward AppView RSS/backfill/retention/recovery settings and Wire rank/enrichment/cleanup settings. Leave the default 30-second lease, 10-second renewal, and 5-second standby retry unless the soak specifically tests a coordinated change.

### Snapshot job

Create snapshots as temporary operator services outside the long-running IaC partial. Set `RAILWAY_DOCKERFILE_PATH=/services/jetstream-ingest/Dockerfile`, configure the legacy single Wire lane (`JETSTREAM_PIPELINE_MODE=wire-global-v1`) with `JETSTREAM_REPLAY_SNAPSHOT_ONLY=true`, `JETSTREAM_EXIT_AFTER_SNAPSHOT=true`, both cursor bounds, a unique source generation, and restart policy `NEVER`. Do not set the namespaced controller enable flags; exit-after-snapshot is rejected in supervised multi-lane mode. Remove the temporary service after recording its completion marker and checkpoint.

## Development cutover

1. Deploy the migration and verify the role-lease table and index exist. Seed each target service with its database, migrator, Redis, API-key, and HMAC references before the first IaC apply; `preserve()` retains existing target values but does not copy them from compatibility services.
2. Link Development and review `railway config plan`. The plan must contain only the three Development indexing resources and no destructive changes. The partial explicitly selects the linked Development or Production profile.
3. Capture the singleton baseline and verify the current roles of compatibility workers. Coordinator is already deployed: retire a compatibility singleton only after proving coverage for each job, and verify it is stopped before changing singleton ownership. Treat a worker configured as a drain as part of the incremental drain handoff.
4. Apply the partial. Verify Ingress Controller's two lane databases, leases, checkpoints, and `/readyz`. Stop the two superseded intake services only after the controller owns the same two leases and cursor movement is continuous.
5. Verify Projection Pool claim/ack partitioning, no duplicate terminal rows, and falling or stable actionable age. Stop the old dedicated Wire drains after the new pool is caught up.
6. Verify Coordinator has exactly one owner for each role, distinct fencing tokens, one active component health endpoint, and one healthy standby path. If the new deployment fails, stop all new Coordinator replicas before restoring either compatibility singleton.
7. Keep superseded hosted worker services stopped and available through the soak and rollback window. Service deletion is outside this release.

## Production cutover

1. Confirm separate Production authorization, merge the reviewed source through `dev` and then protected `main`, and wait for `CI — Required` on both merge previews.
2. Wait for Database Migrator on the exact `main` revision. Verify `20260830190000_add_fenced_role_leases.sql`, the `operations_role_leases` table, and its expiry index before starting Coordinator.
3. Capture the AppView, external Wire, and publication Wire checkpoints, filter fingerprints, lease tokens, actionable backlog by source generation, role ownership, direct Gateway readiness, Wire response metadata, and database connection/storage headroom.
4. Seed the three Production target services with the existing database/migrator references and required secrets before `preserve()` is planned. Do not print decrypted values or use `--show-values`.
5. Link `production` and save a pinned `railway config plan`. Require exactly the three managed service classes, zero deletes, Ingress Controller `2 x us-west2`, Projection Pool `4 x sfo`, and Coordinator `2 x sfo`.
6. Confirm replacement coverage for every Charybdis projection, RSS, backfill, retention and recovery job before stopping it. `The Wire Worker Production` currently runs as a drain; retire it with the other drains after equivalent Projection throughput is demonstrated.
7. Apply the pinned plan. Coordinator must show exactly one fenced owner for each role and a standby replica. Preserve the complete live Projection source union, including V8 live and V9 west, and the wider Coordinator recovery union including completed V8 snapshots. Do not narrow either scope to historical examples.
8. Leave the three legacy intake services running until the new controller replicas are healthy in lease-waiting state. Stop `Jetstream V2 Ingest`, `The Wire Global Ingest Production`, and `The Wire Live Ingest Production` individually, requiring token-incrementing takeover and continuous checkpoint movement after each stop.
9. Let Projection Pool overlap the legacy Wire drains using fenced `SKIP LOCKED` claims. Once AppView remains at zero actionable rows and the scoped Wire backlog/age is no worse than baseline, stop `The Wire Inbox Drain` replicas, `The Wire Fresh Inbox Drain`, and `The Wire Worker Production` incrementally, checking throughput and claims after each change.
10. Require progress across every preserved source generation and a fresh, ranked, non-degraded 50-story Wire generation before completing the cutover.
11. Set Gateway `PROJECTION_POOL_BASE_URL=http://projection-pool.railway.internal:8080` for independent ingestion-health collection. Require Gateway `/readyz` for database/AppView serving availability, and separately require Projection Pool `/readyz` plus complete ingestion evidence before considering Charybdis unavailable for rollback. Gateway can serve while its cached ingestion evidence is degraded or unknown; its HTTP 200 is not a recovery gate.
12. Force one Ingress Controller replica handoff and one Coordinator replica handoff. Require incremented fencing tokens, no skipped/duplicated committed range, exactly one singleton owner per role, and continuing feed/generation progress.
13. Keep all compatibility services stopped but deployable through the Production soak. Deletion is a separate rollback-window decision.

## Soak gates

Hold Development for at least 24 hours, including representative replay and a peak traffic cycle, and verify separately:

- Ingress: both source checkpoints advance; lease renewal is stable; no replay-budget or admission regressions.
- Projection: oldest actionable AppView and Wire inbox age stays within SLO; pending/retrying rows do not trend upward; dead letters do not increase unexpectedly.
- Coordinator: exactly one owner per role; forced replica restart produces token-incrementing takeover within the lease window; no overlapping generations, cleanup passes, RSS polls, or recovery jobs.
- Database: connection count, active queries, storage growth, vacuum pressure, and claim query plans stay within the existing headroom.
- Serving: direct AppView entry/unread/bootstrap checks and Wire edition checks are fresh and non-degraded; authenticated Web and iOS readers show the expected entries and unread state.
- Rollback: pausing the new service and restoring its compatibility service recovers without cursor reset, duplicate source generation, or stale-owner writes.

## Rollback

1. Stop the affected new service class. For Coordinator, wait beyond the lease duration or verify its role rows are released before starting old singleton jobs.
2. Restore the matching compatibility service configuration and replica count without changing source generation or inbox scope.
3. Verify cursor continuity, backlog age, generation freshness, direct HTTP results, and authenticated UI behavior.
4. Keep the additive role-lease migration; it is safe when unused and avoids destructive rollback.
