# The Wire Worker

`wire-worker` independently materializes **The Wire** — **Important stories across the social web**. PostgreSQL is the durable authority for candidates, privacy-safe signal rollups, immutable ranked generations, and the active generation pointer. A future Redis mirror may accelerate reads, but must remain disposable. The complete algorithm contract lives in [`packages/swift/WireCore/README.md`](../../packages/swift/WireCore/README.md).

## Modes

- `WIRE_FEED_MODE=off` (default): perform health probes only; do not load, retain, rank, or publish candidates.
- `WIRE_FEED_MODE=shadow`: build durable generations without moving the serving pointer or exposing public routes.
- `WIRE_FEED_MODE=api`: commit and serve the API while the catalog keeps navigation hidden (`enabled: true`, `available: false`).
- `WIRE_FEED_MODE=visible`: commit and serve the API with catalog navigation enabled and available.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | required | Railway PostgreSQL connection string |
| `WIRE_FEED_MODE` | `off` | Remote rollout switch (`off|shadow|api|visible`) |
| `WIRE_RANK_INTERVAL_SECONDS` | `300` | Five-minute generation cadence |
| `WIRE_CANDIDATE_LIMIT` | `5000` | Maximum rollup rows scored per cycle |
| `WIRE_GENERATION_RETENTION_SECONDS` | `172800` | 48-hour superseded/shadow generation retention |
| `WIRE_RETENTION_BATCH_SIZE` | `5000` | Bounded cleanup batch |
| `WIRE_LANGUAGE_BUCKET` | `und` | Global or language-specific feed bucket |
| `WIRE_ACTOR_HMAC_SECRET` | required outside `off` | Versioned 256-bit minimum actor-key secret |
| `WIRE_BASELINE_LABELERS` | Bluesky Moderation Service | Comma-separated `source-did|https://labeler-host` queryLabels authorities |
| `WIRE_LABEL_REFRESH_MAX_AGE_SECONDS` | `900` | Maximum baseline label snapshot age allowed before activation fails closed |
| `WIRE_INBOX_BATCH_SIZE` | `1000` | Maximum inbox rows claimed by one drain iteration (maximum `5000`) |
| `WIRE_INBOX_CONCURRENCY` | `16` | Maximum independently fenced events applied concurrently (maximum `64`) |
| `WIRE_INBOX_IDLE_MILLISECONDS` | `250` | Backpressure delay after an empty claim; full batches continue immediately |
| `WIRE_POSTGRES_MAX_CONNECTIONS` | `12` | Bounded pool shared by drain, maintenance, ranking, and health work (maximum `64`) |
| `PORT` | `8080` | Health server port |

Health endpoints are `/health`, `/livez`, `/startupz`, and `/readyz`. Startup and readiness fail closed when PostgreSQL cannot be reached. Database migrations remain owned by the dedicated Database Migrator service.

## Baseline moderation labels

Before any non-off generation is built, the worker queries every configured labeler through `com.atproto.label.queryLabels`. It sends exact candidate representative AT-URIs and public source-author DIDs in batches of at most 25, requests at most 250 labels per page, follows at most 20 advancing cursors per batch, and runs at most four batch requests concurrently. Each HTTP request has a five-second timeout and the complete baseline refresh has a 45-second deadline. The default is Bluesky's moderation service (`did:plc:ar7c4by46qjdydhdevvrndac|https://mod.bsky.app`); operators can replace or extend it with `WIRE_BASELINE_LABELERS`.

Network takedown, `!hide`, spam, adult/sexual, and graphic-media labels are projected into `wire_labels`. Negations, expirations, and labels absent from a successfully completed snapshot remove their prior projection atomically for the canonical keys actually queried. Labels on candidates outside the bounded refresh set remain until that candidate is queried or the label expires; a recency-limited refresh can never silently unlabel an unqueried rankable item. Subject DIDs are hashed inside label source keys and never logged or exposed by the API. `wire_label_refresh_state` records only the configured labeler DID/host, bounded target/count totals, and timestamps.

If any endpoint errors, returns malformed attribution, repeats a cursor, exceeds the pagination bound, or cannot produce a fresh snapshot, the last good rows remain intact and the generation cycle fails before commit. Readiness then ages unhealthy with the failed generation cycle; the worker never activates an unmoderated generation.

This baseline verifies transport and attribution, not label signatures: requests are limited to explicitly configured HTTPS endpoints and responses must use the exact configured source DID, but the optional ATProto label `sig` is not yet cryptographically verified against the labeler DID. Signature verification is a remaining hardening item and this implementation must not be described as independently proving label authenticity.

The isolated Go lane stages global events into `wire_ingestion_inbox`. A dedicated runtime continuously claims bounded batches using PostgreSQL fencing and `SKIP LOCKED`. A batch contains only the earliest actionable event for each repository, so up to `WIRE_INBOX_CONCURRENCY` different repositories can apply concurrently without violating per-repository sequence. Ready work is ordered by `next_attempt_at` before sequence, preventing older retry rows in unrelated repositories from monopolizing a bounded claim. Full batches continue immediately; an empty claim waits `WIRE_INBOX_IDLE_MILLISECONDS`. Failures preserve leases/retry state, make readiness unhealthy, and retry with bounded backoff. Unresolved Standard Site publication references retry for at most 24 hours before dead-lettering, so a permanently missing public dependency cannot hold a repository forever. One process therefore applies at most one bounded batch at a time and cannot create an unbounded in-memory queue.

The default event concurrency of 16 intentionally exceeds the 12-connection PostgreSQL pool. PostgreSQL pool queuing is the database backpressure boundary while JSON decoding and canonicalization work remain in flight; the worker never opens more than `WIRE_POSTGRES_MAX_CONNECTIONS` database connections.

Graph pruning, six-hour community refresh checks, and exact rollup rebuilding run once with the five-minute generation cycle rather than after every inbox batch. Baseline label refresh and ranking also remain on that five-minute cadence, so an archive drain cannot hammer labelers. Readiness requires both a recent successful generation cycle and either a recently completed drain iteration or an in-flight batch younger than three minutes.

The worker observes `site.standard.publication` commits into the rebuildable `wire_publications` PostgreSQL projection. A Standard Site document with a publication AT-URI plus relative `path` resolves from that durable projection, then from a bounded public-HTTPS PLC/PDS lookup with 64 KiB response limits, timeouts, negative caching, and in-flight request coalescing. Immediately before every PLC and PDS request, the worker resolves DNS again and rejects the entire answer set if any address is loopback, link-local, private, documentation, multicast, or otherwise non-global. At most eight blocking resolver calls may remain active, each caller waits at most three seconds, and redirects are not followed. Direct article URLs and HTTPS publication-site-plus-path records remain local and require no network lookup. Unsafe or structurally invalid endpoints are terminal; absent, timed-out, or transient publication dependencies remain retryable within the 24-hour bound.

The worker resolves supported article/share/reference/follow events, stores only keyed actor hashes in signal/graph tables, retracts deletes and inactive accounts, rebuilds exact rolling rollups, and then materializes immutable generations. Raw signals carry a generation-independent transport key derived from environment, source host, cursor kind, and sequence. Source-record updates replace only older signal state and older deletes cannot retract newer state, so overlapping successor backfills do not inflate rolling counts.
