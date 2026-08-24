# Railway Deployment Configuration

Railway is the canonical deployment platform for both Development and Production. GitHub Actions validates source changes; Railway deploys successful linked revisions through its GitHub integration.

These custom-named config-as-code files are inactive until each Railway service selects its exact file under **Settings → Config-as-code**. Keep each service root directory at `/` so Docker and Railpack builds can access shared monorepo packages.

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

Database Migrator is the sole schema owner. Give it
`DATABASE_URL=${{Postgres.DATABASE_URL}}`. Each database-consuming application
service must also define
`DATABASE_MIGRATOR_SERVICE_ID=${{Database Migrator.RAILWAY_SERVICE_ID}}` so
Railway's reference-variable deployment ordering waits for a successful
migration deployment before starting the new application revision. The
migrator exits after applying pending migrations and uses restart policy
`NEVER`; it has no public domain or long-running replica.

Redis is currently provisioned in Development and Production with private
networking, co-located with Gateway/App View/Charybdis and Postgres in US West.
Those three services reference `REDIS_URL` and currently select the Redis
backends. Jetstream V2 Ingest and The Wire Global Ingest deliberately keep
cursor durability in Postgres and do not depend on Redis. The Wire Worker may
use Redis only for disposable candidate/page acceleration; PostgreSQL remains
authoritative. Configure `allkeys-lru`, retain the Postgres cache
tables as rollback targets, and follow the Development-first change discipline
in [`docs/architecture/redis.md`](../docs/architecture/redis.md) before future
Production changes.

Secrets, reference variables, custom domains, volumes, and region placement remain environment-specific Railway settings. Gateway, App View, Charybdis, Ops, Jetstream V2 Ingest, The Wire Global Ingest, and The Wire Worker expose `/readyz`. Railway deploys Charybdis and both ingestion lanes against `/startupz` so durable catch-up or fenced-lease handoff can complete without weakening their operational readiness probes. The Wire Worker also deploys against `/startupz` while Development shadow generations warm.

The Wire Corpus Edge exists only in Production and connects to Production
Postgres over the private network. Its narrowly exposed HTTPS domain accepts
only dedicated nonce-protected service signatures from Development App View;
it never accepts viewer or Gateway/AppView trust credentials. Development
App View receives only the edge URL and its edge-client secret, never a
Production database credential.

The Wire Fresh Inbox Drain is a separately scoped Production drain. Configure
it with `APP_ENV=prod`, `WIRE_FEED_MODE=api`, `WIRE_WORKER_ROLE=drain`,
and `WIRE_INBOX_SOURCE_GENERATIONS=wire-global-v4-prod-live-tail-v1`, plus the
same Postgres, migrator, and actor HMAC references as the existing Wire drains.
Keep inbox cleanup enabled: the source scope applies to terminal cleanup too,
so it bounds v4 rows without changing retained historical rows. Before its
first start, stop the v3 producer and every unscoped drain and wait more than
the 120-second inbox lease period. Do not run an unscoped or historical drain
alongside it.
