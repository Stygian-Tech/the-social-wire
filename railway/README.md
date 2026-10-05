# Railway Deployment Configuration

Railway is the canonical deployment platform for both Development and Production. GitHub Actions validates source changes; Railway deploys successful linked revisions through its GitHub integration.

The files in this directory are grandfathered per-service Config as Code for
compatibility services. Railway no longer allows new services to select these
files. The consolidated Ingress Controller, Projection Pool, and Coordinator
are managed by the scoped Infrastructure as Code partial in
`/.railway/railway.ts`. Keep service build roots at `/` so Docker and Railpack
builds can access shared monorepo packages.

| Railway Service | Config File |
| --- | --- |
| Web | `/railway/web.json` |
| Operations Web | `/railway/operations-web.json` |
| Gateway | `/railway/gateway.json` |
| App View | `/railway/appview.json` |
| Charybdis | `/railway/charybdis.json` |
| Jetstream V2 Ingest | `/railway/jetstream-ingest.json` |
| The Wire Global Ingest | `/railway/wire-jetstream-ingest.json` |
| The Wire Worker | `/railway/wire-worker.json` |
| The Wire Inbox Drain | `/railway/wire-inbox-drain.json` |
| The Wire Fresh Inbox Drain | `/railway/wire-fresh-inbox-drain.json` |
| The Wire Corpus Edge | `/railway/wire-corpus-edge.json` |
| Ops | `/railway/operations.json` |
| Database Migrator | `/railway/database-migrator.json` |

The repository-owned Tap image and `/railway/tap.json` were retired on
2026-08-16. Removing a pre-existing hosted Tap service and its Charybdis
credentials is a separate environment-scoped operator action; this source
change does not mutate Railway or Production.

The Development environment must track the `dev` branch. The Production environment must track `main`. Railway Postgres and Redis use Railway templates and do not need repository config files.

Database Migrator is the sole main-database schema owner. Give it
`DATABASE_URL=${{Postgres.DATABASE_URL}}`. Keep
`DATABASE_MIGRATOR_SERVICE_ID=${{Database Migrator.RAILWAY_SERVICE_ID}}` on its
consumers for batched deployment ordering, but reference ordering **does not
apply to GitHub push deployments**, including monorepos ([Railway documentation](https://docs.railway.com/deployments/deployment-actions#when-ordering-does-not-apply)).
The migrator exits after applying pending migrations with restart policy `NEVER`.

Main-database consumer images start through `schema-ready`. Before any application
listener, intake, lease or maintenance task starts, it checks every migration
version packaged with that image against committed `public.schema_migrations`
receipts. A missing ledger or receipt waits up to 90 seconds, then fails startup;
Railway retains the previous healthy deployment when the replacement fails its
health check. The migrator remains the only schema writer. The gate holds at most
one read-only connection, with bounded queries and SIGTERM cancellation, and
closes it before replacing itself with the application. Extra newer receipts are
allowed so older compatible images can roll back without resetting schema.

Gateway/AppView images can skip PostgreSQL only for local SQLite (`APP_ENV=local`
or unset outside Railway). Other covered images require `APP_ENV=dev|prod` and
`DATABASE_URL`; Railway always requires both. Main-database images cover Ingress,
Projection Pool/Coordinator, Gateway, App View, Operations, and their legacy
AppView/Wire workers. Corpus Edge uses its separate schema, migrator and reader
role, so it is excluded, as are HTTP-only Web/Operations Web and the migrators.
No service may override the image entrypoint with a custom start command that
omits `schema-ready`. A gate timeout needs migration completion followed by a
retry of the same revision; never bypass the gate or insert synthetic receipts.

Redis is currently provisioned in Development and Production with private
networking, co-located with Gateway/App View/indexing workers and Postgres in US West.
Those services reference `REDIS_URL` where their role uses projection caches.
Ingress Controller deliberately keeps
cursor durability in Postgres and does not depend on Redis. The Wire Worker may
use Redis only for disposable candidate/page acceleration; PostgreSQL remains
authoritative. Configure `allkeys-lru`, retain the Postgres cache
tables as rollback targets, and follow the Development-first change discipline
in [`docs/architecture/redis.md`](../docs/architecture/redis.md) before future
Production changes.

Secrets and reference variables remain environment-specific Railway settings.
The indexing IaC partial preserves them and owns the three services' source,
Dockerfile, watch paths, US-West replica count, startup health check, and restart
policy. Gateway, App View, Ingress Controller, Projection Pool, Coordinator,
and Ops expose `/readyz`. Railway deploys the indexing classes against
`/startupz` so durable catch-up or fenced-lease handoff can complete without
weakening their operational readiness probes. Compatibility worker configs
remain checked in through the rollback window. Snapshot jobs are temporary
operator services with restart policy `NEVER`, not persistent IaC resources.

The Wire Corpus Edge instance connects to Production
Postgres over the private network. Its narrowly exposed HTTPS domain accepts
only dedicated nonce-protected service signatures from Development App View;
it never accepts viewer or Gateway/AppView trust credentials. Development
App View receives only the edge URL and its edge-client secret, never a
Production database credential.

Finance has a separate Development **Finance Corpus Edge** instance connected to
Development Postgres with a view-only login. App View uses
`FINANCE_CORPUS_EDGE_BASE_URL`, `FINANCE_CORPUS_EDGE_SERVICE_ID`, and
`FINANCE_CORPUS_EDGE_HMAC_SECRET` for Finance generation, fallback, and item checks;
existing Wire routing is preserved. Development permits authenticated HTTP only
to Railway private `.railway.internal` origins. The Finance edge has no public
domain and runs beside its Postgres volume in `sfo`.

Development Finance Corpus Edge sets `WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS=1`.
Its view-only role has a two-connection limit, so the old and new containers each
retain one connection during rolling deployments. This service remains outside
the consolidated indexing IaC partial; preserve its dedicated connection setting.

The Wire Fresh Inbox Drain is a separately scoped Production drain. Configure
it with `APP_ENV=prod`, `WIRE_FEED_MODE=api`, `WIRE_WORKER_ROLE=drain`,
and `WIRE_INBOX_SOURCE_GENERATIONS=wire-global-v4-prod-live-tail-v1`, plus the
same Postgres, migrator, and actor HMAC references as the existing Wire drains.
Keep inbox cleanup enabled: the source scope applies to terminal cleanup too,
so it bounds v4 rows without changing retained historical rows. Set
`WIRE_INBOX_CLEANUP_ENABLED=false` on the singleton rank service while this
scoped drain owns cleanup; rank does not claim inbox work, but its cleanup loop
is otherwise unscoped. Before the scoped drain's first start, stop the historical
producer and every unscoped drain and wait more than the 120-second inbox lease
period. Do not run an unscoped or historical drain alongside it.
