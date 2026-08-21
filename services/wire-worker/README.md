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
| `POSTGRES_MAX_CONNECTIONS` | n/a | Intentionally not used; this worker reserves two connections |
| `PORT` | `8080` | Health server port |

Health endpoints are `/health`, `/livez`, `/startupz`, and `/readyz`. Startup and readiness fail closed when PostgreSQL cannot be reached. Database migrations remain owned by the dedicated Database Migrator service.

## Baseline moderation labels

Before any non-off generation is built, the worker queries every configured labeler through `com.atproto.label.queryLabels`. It sends exact candidate representative AT-URIs and public source-author DIDs in batches of at most 25, requests at most 250 labels per page, follows at most 20 advancing cursors per batch, and runs at most four batch requests concurrently. Each HTTP request has a five-second timeout and the complete baseline refresh has a 45-second deadline. The default is Bluesky's moderation service (`did:plc:ar7c4by46qjdydhdevvrndac|https://mod.bsky.app`); operators can replace or extend it with `WIRE_BASELINE_LABELERS`.

Network takedown, `!hide`, spam, adult/sexual, and graphic-media labels are projected into `wire_labels`. Negations, expirations, and labels absent from a successfully completed snapshot remove their prior projection atomically for the canonical keys actually queried. Labels on candidates outside the bounded refresh set remain until that candidate is queried or the label expires; a recency-limited refresh can never silently unlabel an unqueried rankable item. Subject DIDs are hashed inside label source keys and never logged or exposed by the API. `wire_label_refresh_state` records only the configured labeler DID/host, bounded target/count totals, and timestamps.

If any endpoint errors, returns malformed attribution, repeats a cursor, exceeds the pagination bound, or cannot produce a fresh snapshot, the last good rows remain intact and the generation cycle fails before commit. Readiness then ages unhealthy with the failed generation cycle; the worker never activates an unmoderated generation.

This baseline verifies transport and attribution, not label signatures: requests are limited to explicitly configured HTTPS endpoints and responses must use the exact configured source DID, but the optional ATProto label `sig` is not yet cryptographically verified against the labeler DID. Signature verification is a remaining hardening item and this implementation must not be described as independently proving label authenticity.

The isolated Go lane stages global events into `wire_ingestion_inbox`. This worker claims that inbox, resolves supported article/share/reference/follow events, stores only keyed actor hashes in signal/graph tables, retracts deletes and inactive accounts, rebuilds exact rolling rollups, and then materializes immutable generations.
