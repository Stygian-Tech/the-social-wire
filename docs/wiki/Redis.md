# Redis

Redis is an optional, disposable cache and coordination layer for Gateway, AppView, and Charybdis. It never replaces an authoritative PDS or durable Postgres state.

## Current hosted selection

As verified on 2026-08-12, Development and Production each have a private Redis.
Gateway selects `GATEWAY_PDS_CACHE_BACKEND=redis`, while AppView and Charybdis
select `APPVIEW_CACHE_BACKEND=redis` in both environments. All three services
have an environment-local `REDIS_URL`.

Redis remains an optional side-cache in the architecture: PDS/Postgres are
authoritative, Postgres cache tables remain available for rollback, and a Redis
failure must fail open to durable sources. Future Redis configuration or version
changes still require Development-first drills, authenticated QA, soak evidence,
and review before Production.

## What Redis provides

- stale-first sidebar, unread-count, and first-page projection caches;
- Gateway PDS-record acceleration;
- shared PLC resolution caching and request coalescing;
- distributed projection-rebuild and RSS polling leases;
- reusable sorted-set ranking primitives; and
- bounded Operations cache and server metrics.

The current product feed is still ordered from Postgres-backed projection data;
the sorted-set API is an available primitive, not an active ranking dependency.

Keys hash DIDs, URLs, and AT-URIs with full SHA-256. Broad invalidation uses cursor-based `SCAN` and batched `UNLINK`; `KEYS` is prohibited.

## Failure behavior

A Redis read failure is treated as a cache miss. Durable mutations continue against PDS/Postgres, reads reconstruct from durable sources, and Redis availability is not part of readiness. Circuit breaking and bounded command timeouts prevent a failing Redis service from dominating request latency.

Postgres cache tables remain available as the normal backend where Redis is not selected and as a rollback target during a Redis rollout. An environment in Redis mode does not read or write those cache tables, so rollback includes invalidating their stale rows before sending traffic back to them.

## Configuration

| Surface | Selector |
|---------|----------|
| Gateway PDS record cache | `GATEWAY_PDS_CACHE_BACKEND=sqlite|postgres|redis` |
| AppView/Charybdis projections | `APPVIEW_CACHE_BACKEND=sqlite|postgres|redis` |
| Connection | `REDIS_URL=redis://…` or `rediss://…` |

Canonical policies, TTLs, key formats, drills, and rollback: [docs/architecture/redis.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/redis.md).

Related: [[Architecture]], [[Database]], [[Deployment-and-environments]], [[Operations]].
