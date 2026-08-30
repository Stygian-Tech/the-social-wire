# Indexing service consolidation rollout

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
2. Run `railway environment link dev` and review `railway config plan`. The plan must contain only the three Development indexing resources and no destructive changes. The partial aborts outside Development.
3. Capture the singleton baseline, stop compatibility `Charybdis` and `The Wire Worker`, and verify their deployments are stopped before applying the `indexing-consolidation` partial. This creates a bounded maintenance gap and prevents the old unfenced RSS, recovery, retention, ranking, enrichment, and cleanup loops from overlapping the new Coordinator.
4. Apply the partial. Verify Ingress Controller's two lane databases, leases, checkpoints, and `/readyz`. Stop the two superseded intake services only after the controller owns the same two leases and cursor movement is continuous.
5. Verify Projection Pool claim/ack partitioning, no duplicate terminal rows, and falling or stable actionable age. Stop the old dedicated Wire drains after the new pool is caught up.
6. Verify Coordinator has exactly one owner for each role, distinct fencing tokens, one active component health endpoint, and one healthy standby path. If the new deployment fails, stop all new Coordinator replicas before restoring either compatibility singleton.
7. Stop and remove the superseded hosted worker services only after the soak. Keep their config files and executable products through the rollback window.

## Soak gates

Hold Development for at least one peak traffic cycle and verify separately:

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
