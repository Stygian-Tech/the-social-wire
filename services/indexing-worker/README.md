# Indexing Worker

This package is the shared Swift runtime for two independently replicated Railway service classes:

- `INDEXING_WORKER_ROLE=projection` runs the AppView durable-inbox projector and The Wire inbox drain. It is horizontally scalable; PostgreSQL claim/ack semantics partition work across replicas.
- `INDEXING_WORKER_ROLE=coordinator` runs AppView RSS/backfill/retention/recovery jobs and The Wire generation/enrichment/cleanup jobs. Two replicas may run, but independent fenced leases allow exactly one active owner per subsystem while the other remains a healthy standby.

The existing `AppViewWorker` and `WireWorker` executables remain available during migration and rollback. Do not run legacy workers and their replacement role against the same authoritative lane after cutover.

Required hosted variables include `APP_ENV`, `DATABASE_URL`, `ENABLE_THIN_APPVIEW=true`, `INDEXING_WORKER_ROLE`, and the existing AppView/Wire role-specific settings and secrets. Coordinator lease timing defaults to a 30-second lease, 10-second renewal, and 5-second standby retry; override with `INDEXING_ROLE_LEASE_SECONDS`, `INDEXING_ROLE_LEASE_RENEW_SECONDS`, and `INDEXING_ROLE_STANDBY_RETRY_SECONDS` only as a coordinated operational change.

The public health listener uses `PORT`. Private component probes bind loopback on `PORT + 1` and `PORT + 2` by default. `/startupz` verifies PostgreSQL and component startup. `/readyz` verifies both active projection lanes; coordinator standby replicas report ready while active owners must also pass their component readiness checks.

Run locally:

```sh
swift test
INDEXING_WORKER_ROLE=projection APP_ENV=dev DATABASE_URL='postgresql://…' ENABLE_THIN_APPVIEW=true swift run IndexingWorker
```
