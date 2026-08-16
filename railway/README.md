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
| Tap | `/railway/tap.json` |

The Development environment must track the `dev` branch. The Production environment must track `main`. Railway Postgres and Redis use Railway templates and do not need repository config files.

Redis is currently provisioned in Development and Production with private
networking, co-located with Gateway/App View/Charybdis and Postgres in US West.
Those three services reference `REDIS_URL` and currently select the Redis
backends. Jetstream V2 Ingest deliberately keeps cursor durability in Postgres
and does not depend on Redis. Configure `allkeys-lru`, retain the Postgres cache
tables as rollback targets, and follow the Development-first change discipline
in [`docs/architecture/redis.md`](../docs/architecture/redis.md) before future
Production changes.

Secrets, reference variables, custom domains, volumes, and region placement remain environment-specific Railway settings. Gateway, App View, Ops, and Jetstream V2 Ingest expose `/readyz`; Charybdis and Tap do not expose HTTP health endpoints.
