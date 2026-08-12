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
| Ops | `/railway/operations.json` |
| Tap | `/railway/tap.json` |

The Development environment must track the `dev` branch. The Production environment must track `main`. Railway Postgres and Redis use Railway templates and do not need repository config files.

Provision Redis separately per environment with private networking only, co-located with Gateway/App View/Charybdis and Postgres in US West. Configure `allkeys-lru`, reference `REDIS_URL=${{Redis.REDIS_URL}}` from those three services, and follow the Development-first gates in [`docs/architecture/redis.md`](../docs/architecture/redis.md). Keep `GATEWAY_PDS_CACHE_BACKEND=postgres` and `APPVIEW_CACHE_BACKEND=postgres` until the baseline is recorded; Production remains unchanged until explicit approval.

Secrets, reference variables, custom domains, volumes, and region placement remain environment-specific Railway settings. Gateway, App View, and Ops expose `/readyz`; Charybdis and Tap do not expose HTTP health endpoints.
