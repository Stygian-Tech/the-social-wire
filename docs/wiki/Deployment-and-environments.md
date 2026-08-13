# Deployment and environments

Development and Production are isolated Railway environments. GitHub Actions validates source changes; Railway deploys linked revisions through its GitHub integration after the required checks pass.

| Environment | Branch | Web | Gateway | Operations console |
|-------------|--------|-----|---------|--------------------|
| Development | `dev` | `testing.thesocialwire.app` | `api.testing.thesocialwire.app` | `operations.testing.thesocialwire.app` |
| Production | `main` | `thesocialwire.app` | `api.thesocialwire.app` | `operations.thesocialwire.app` |

Generated `*.up.railway.app` domains are deployment diagnostics. OAuth client IDs, redirect URIs, CORS origins, and public documentation use the stable custom domains.

## Deployed services

Railway config-as-code files under `railway/` define seven application services:

| Service | Config |
|---------|--------|
| Web | `railway/web.json` |
| Operations Web | `railway/operations-web.json` |
| Gateway | `railway/gateway.json` |
| AppView | `railway/appview.json` |
| Charybdis | `railway/charybdis.json` |
| Operations | `railway/operations.json` |
| Tap | `railway/tap.json` |

Railway Postgres is the canonical hosted database. Gateway's pre-deploy command applies the provider-neutral migration history before startup. GitHub Actions never deploys services or mutates hosted databases.

## Internal networking and regions

Gateway, AppView, Charybdis, Operations, Tap, and their databases communicate over Railway private networking. Database-bound compute and its Postgres service must remain co-located in the same US West region. The hosted data-residency scope is the United States.

## Redis rollout status

Redis is architecturally optional and selected independently with
`GATEWAY_PDS_CACHE_BACKEND` and `APPVIEW_CACHE_BACKEND`. As verified on
2026-08-12, Gateway, AppView, and Charybdis select Redis in both Development and
Production. Postgres remains durable and its cache tables remain the rollback
backend. Future Redis changes must still be exercised and soaked in Development
before Production. See [[Redis]].

## Configuration safety

- Set the exact config path on each Railway service; repository files are inactive until selected in Railway.
- Keep Development on `dev` and Production on `main`.
- Store secrets and Railway reference variables only in the matching environment.
- Validate testing Web, Gateway, OAuth metadata, and native sign-in before production changes.
- Do not advertise an environment as healthy based on a successful build alone; verify health, TLS, OAuth, and a signed-in user flow.

Canonical deployment reference: [railway/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/railway/README.md).

Related: [[Service-API]], [[Operations]], [[Testing]].
