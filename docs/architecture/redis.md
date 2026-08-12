# Redis cache, coordination, and ranking

Redis is an optional, disposable acceleration layer for hosted Gateway, AppView, and Charybdis processes. PDS records remain authoritative on the relevant repository, and Postgres remains authoritative for rebuildable source/index state such as `content_items`, read marks and floors, materialized unread counters, RSS fetch metadata, ingestion/repair state, and Operations evidence. Flushing or losing Redis must not lose durable state or make `/readyz` fail.

## Runtime selection

| Service | Flag | Local default | Hosted pre-cutover default |
|---|---|---|---|
| Gateway PDS records | `GATEWAY_PDS_CACHE_BACKEND=sqlite\|postgres\|redis` | `sqlite` | `postgres` |
| AppView and Charybdis projections | `APPVIEW_CACHE_BACKEND=sqlite\|postgres\|redis` | `sqlite` | `postgres` |

`REDIS_URL` accepts `redis://` and `rediss://`. Redis selection without a usable URL installs an unavailable/fail-open cache: reads reconstruct from PDS/Postgres, writes and invalidations continue durably, and readiness remains based on durable dependencies. Pool defaults are 1–8 connections with a 250 ms command timeout. The circuit opens after three consecutive command failures, probes after five seconds, and backs off to at most 30 seconds.

## Keys and expiry

All identifiers are full lowercase SHA-256 hex digests; raw DIDs, URLs, AT-URIs, and Redis keys are never metric dimensions or log fields.

| Domain | Format | Fresh | Hard expiry |
|---|---|---:|---:|
| Sidebar | `sw:<env>:v1:sidebar:<viewerHash>` | 1 hour | 6 hours |
| Unread | `sw:<env>:v1:unread:<viewerHash>:<publicationHash>` | 2 minutes | 15 minutes |
| First page | `sw:<env>:v1:firstpage:<publicationHash>:<viewerHash>` | 5 minutes | 30 minutes |
| PDS record | `sw:<env>:v1:pds:<ownerHash>:<recordHash>` | 2 minutes; preferences 5 minutes | 20 minutes; preferences 30 minutes |
| PLC resolution | `sw:<env>:v1:pds-resolution:<didHash>` | 30 minutes resolved; 1 minute unresolved | 6 hours resolved; 5 minutes unresolved |
| Lease | `sw:<env>:v1:lock:<domain>:<resourceHash>` | n/a | operation TTL |
| Ranking | `sw:<env>:v1:rank:<feed>:<window>[:<viewerHash>]` | n/a | window TTL |

Cache values carry schema version, cache time, fresh boundary, and hard-expiry boundary. Redis `PEXPIRE` applies hard expiry with up to 10% jitter. Malformed, incompatible, or hard-expired values are measured misses and are removed. Broad invalidation uses cursor-based `SCAN` and batched `UNLINK`; `KEYS` is forbidden.

## Request behavior

Fresh values return immediately. Stale values return immediately while one lease owner refreshes. On a cold miss, one owner rebuilds; contenders wait up to 250 ms for the cache to appear, then compute from the durable source instead of failing. Redis read failures become misses, while write/invalidation failures do not fail the durable operation.

Unread values are stored per viewer/publication. A cached zero is known zero; an absent key is unknown. Partial hits retain known values while only missing or dirty publications are reconstructed from Postgres materialized counters. First-page payloads remain pre-read-state, and viewer read state is resolved after every cache retrieval. The public bootstrap NDJSON shape is unchanged.

PLC resolution caches confirmed endpoints and confirmed unresolved responses. Timeouts, connection failures, 429s, and 5xx responses are not negative-cached. Every cached endpoint passes the existing network-safety validator again before use.

RSS fetch metadata, ETags, backoff, and error counts remain durable. A 120-second renewable Redis lease prevents duplicate feed fetch/ingest work across replicas. If Redis is unavailable, ingestion continues; canonical article identity prevents duplicate durable rows if a lease is lost.

## Ranking primitives

`SocialWireRedis` exposes global and viewer-circle sorted-set scopes, one-hour/24-hour/seven-day windows, finite-score candidates, upsert/remove/top/trim/expiry operations, and Redis lexical member ordering for deterministic equal-score ties. Sets are disposable and rebuildable. TSW-46 does not add feed routes, ranking weights, moderation rules, client navigation, or production selection. Redis Streams and queues are out of scope.

## Operations and failure drills

Operations consumes the existing generic metrics API. Metrics contain bounded service/operation/cache/outcome/error/recompute dimensions only. The AppView panel shows fresh/stale/miss/malformed/fallback counts, average and maximum command duration, locks and contention, errors/circuit state, unread recomputation, and 60-second Redis expiration/eviction/memory samples. These rollups are not percentile distributions and must not be labeled p95.

Flushing Redis should cause automatic reconstruction. Stopping Redis should preserve correct 2xx reads where durable sources are available, successful durable mutations, and healthy readiness. Postgres cache tables remain during rollout solely as a rollback target; Redis mode neither reads nor writes them.

## Development-first rollout

Provision a private Development Redis in the same US West region as compute/Postgres, set `REDIS_URL=${{Redis.REDIS_URL}}` on Gateway, App View, and Charybdis, and configure `allkeys-lru`. Deploy initially with both backend flags still `postgres`; capture a one-hour baseline, switch Gateway first, then AppView and Charybdis together. Exercise concurrency, flush, and outage drills and soak for at least 24 hours. Production must not be provisioned or changed until the Development evidence is reviewed and explicitly approved.

Rollback switches the affected backend flag to `postgres` and invalidates only `sidebar_projection_cache`, `unread_counts_cache`, `first_page_cache`, and `pds_repo_record_cache` before rollback traffic, because those rows stopped receiving writes during Redis mode. Preserve Redis diagnostics and never alter durable content, read-state, RSS metadata, ingestion, repair, or Operations tables.
