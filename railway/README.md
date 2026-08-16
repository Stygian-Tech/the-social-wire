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
backends. Jetstream V2 Ingest deliberately keeps cursor durability in Postgres
and does not depend on Redis. Configure `allkeys-lru`, retain the Postgres cache
tables as rollback targets, and follow the Development-first change discipline
in [`docs/architecture/redis.md`](../docs/architecture/redis.md) before future
Production changes.

Secrets, reference variables, custom domains, volumes, and region placement remain environment-specific Railway settings. Gateway, App View, Charybdis, Ops, and Jetstream V2 Ingest expose `/readyz`.
