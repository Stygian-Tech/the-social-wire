# Replicated indexing and ingestion services

The ingestion and indexing control plane is implemented as three replicated service classes plus ephemeral snapshot jobs. Gateway, App View, Operations, Database Migrator, and Wire Corpus Edge remain independent because they have different public contracts, scaling signals, or deployment authority.

| Service class | Runtime | Default replicas | Responsibilities |
| --- | --- | ---: | --- |
| Ingress Controller | `services/jetstream-ingest` | 2 | AppView and Wire Jetstream lanes, each with its own database handle, source identity, fenced intake lease, health state, and restart lifecycle |
| Projection Pool | `services/indexing-worker`, role `projection` | N | AppView durable-inbox projection and Wire inbox drain; PostgreSQL claim/ack semantics partition work across replicas |
| Coordinator | `services/indexing-worker`, role `coordinator` | 2 | AppView RSS polling/backfill/retention/recovery and Wire rank/enrichment/cleanup; independent fenced leases select one active owner per subsystem |
| Ingress Snapshot Job | `services/jetstream-ingest` legacy single-lane snapshot mode | 0 normally | Bounded, operator-created replay snapshots; exits after the bounded range and uses restart policy `NEVER` |

```text
Jetstream archive / live tail
            │
            ▼
Ingress Controller ×2
  ├─ AppView lane ── fenced intake lease ── appview durable inbox
  └─ Wire lane ───── fenced intake lease ── wire durable inbox
            │
            ▼
Projection Pool ×N
  ├─ AppView projector (claim / project / ack)
  └─ Wire drain       (claim / project / ack)
            │
            ├──────────────► App View read service
            └──────────────► Wire Corpus Edge

Coordinator ×2
  ├─ appview-coordinator lease ── RSS / backfill / TTL / recovery
  └─ wire-materializer lease ─── rank / enrich / cleanup
```

## Isolation and compatibility

The Go intake-to-Postgres-inbox-to-Swift-projector boundary remains intact. A single Ingress Controller process hosts both intake lanes, but a lane failure restarts only that lane. `/status` reports lane state separately; `/startupz` and `/readyz` fail closed if a configured continuous lane is unhealthy.

The Swift `AppViewWorkerCore` and `WireWorkerCore` libraries expose their existing runtimes without merging their stores, database pools, or domain logic. Projection Pool independently supervises both runtimes and probes their loopback health listeners. A failed AppView projector does not terminate the Wire drain, and vice versa.

The old `AppViewWorker` and `WireWorker` executables remain buildable during the migration window. Their compatibility defaults are unchanged. They are rollback artifacts, not additional steady-state service classes.

## Singleton fencing

Coordinator replicas use `operations_role_leases`, keyed by `(environment, role)`. Takeover increments a monotonic fencing token. Renew, release, and fenced commit entry require the exact owner and token, so a stale owner cannot regain authority after lease loss.

The two Coordinator subsystems use distinct roles:

- `indexing.appview-coordinator`
- `indexing.wire-materializer`

This allows one subsystem to fail over without moving the other. A replica with neither lease remains a healthy standby as long as it can reach PostgreSQL and its lease supervisors are running. When it owns a role, its component health must also pass.

## Scaling signals

- Scale Ingress Controller only for availability. Fenced lane ownership keeps one active intake owner per source generation.
- Scale Projection Pool from actionable inbox age, pending rows, claim latency, and database connection headroom.
- Keep Coordinator at two replicas. Additional replicas add standby connections without increasing singleton throughput.
- Run snapshots as bounded jobs with a unique source generation and explicit cursor bounds. Never place snapshot mode under an always-restart supervisor.

## Deployment ownership

Railway config-as-code lives at:

- `/railway/ingress-controller.json`
- `/railway/projection-pool.json`
- `/railway/coordinator.json`
- `/railway/ingress-snapshot-job.json`

Database Migrator remains the only schema owner. All three long-running service classes reference its Railway service ID so a successful migration precedes application startup. Environment cutover and rollback steps are in [the consolidation runbook](../runbooks/operations/indexing-service-consolidation.md).
