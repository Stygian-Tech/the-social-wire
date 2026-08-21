# The Wire

**The Wire** — **Important stories across the social web** — is The Social Wire's global, non-personalized edition of important public stories. This document is the algorithm and data-contract source of truth for `WireCore`, the independent `wire-worker`, ingestion producers, and serving adapters. A behavior change is incomplete until code, tests, configuration version, and this document change together.

## End-to-end flow

1. Public Jetstream/RSS producers place idempotent envelopes in `wire_ingestion_inbox`. The durable inbox owns retry, lease, dead-letter, and expiry state; a network message is not considered accepted until PostgreSQL has it.
2. A dedicated drain runtime continuously claims bounded inbox batches, applies different repositories concurrently while preserving repository FIFO, and uses bounded idle/error backoff. Claims order ready work by retry time before sequence so retries in one repository cannot starve unrelated pending repositories. The applier canonicalizes the linked story, upserts `wire_items` plus `wire_item_aliases`, records presentation-safe provenance, applies moderation/source labels, and inserts a deduplicated `wire_signal_events` row. Standard Site publication records form a rebuildable PostgreSQL resolver projection; documents carrying a publication AT-URI plus relative path use that projection or a bounded public PLC/PDS lookup. PLC/PDS DNS is revalidated immediately before every request, mixed or non-global answer sets fail closed, and redirects are not followed. Unresolved dependencies retry for no more than 24 hours.
3. The applier updates bounded, keyed-hash graph state (`wire_active_actors`, `wire_follow_edges`, `wire_actor_communities`) and privacy-safe aggregate counts in `wire_signal_rollups`. DIDs for sharers, likers, reposters, and other engagement actors never enter a serving row. A public source/author DID may be retained only with its public item for attribution and viewer block/mute filtering; it is never a ranking feature or community identifier.
4. Every five minutes by default, `wire-worker` prunes bounded graph state, refreshes community assignments when due, rebuilds exact rollups, refreshes baseline labels, loads eligible item/rollup rows, computes the deterministic `wire-v1` score, applies first-page diversity, and writes an immutable `wire_rank_generations` plus its `wire_ranked_items`. Continuous archive draining never increases labeler cadence.
5. In `shadow` mode the generation remains queryable for comparison but is not served. In `api` or `visible` mode the worker moves `wire_feed_state.active_generation_id` in the same PostgreSQL transaction as the completed generation. `off` performs read-only health probes and no data operation.
6. An AppView `WireFeedStore` serving adapter reads the active generation, joins the presentation snapshot, filters labels again, and returns the approved `WirePage`, `WireItemDetail`, or singleton `WireFeedCatalog` contract. A Redis copy may be read first, but a miss or disagreement always resolves from PostgreSQL.

The backend implements the durable schema, inbox applier and rollups, domain algorithm, generation worker, and AppView serving adapter. Operator mode remains the final authority: the catalog reports navigation available only in `visible`, and rollout begins in `off`/`shadow` while the corpus and moderation evidence are evaluated.

## Canonical identity

`WireCanonicalizer.version` is `canonical-url-v1`. It accepts only HTTP(S) URLs without user info and then:

- promotes `http` to `https`;
- lowercases the host and removes port 80/443;
- removes fragments and trailing slashes except the root slash;
- removes only known tracking keys (`utm_*`, `dclid`, `fbclid`, `gclid`, `igshid`, `mc_cid`, `mc_eid`, `msclkid`);
- preserves semantic query parameters and sorts them by name then value;
- hashes the canonical URL with SHA-256 as `url:<64 lowercase hex characters>`.

Aliases (AT URI, redirect, syndication, or alternate URL) point to one canonical key. Canonicalizer changes require a new version, dual-writing old/new aliases during a bounded migration, a replay comparison, and an explicit cutover. Never silently reinterpret an existing canonical key.

Example: `http://EXAMPLE.com:80/story/?utm_source=x&b=2&a=1#comments` becomes `https://example.com/story?a=1&b=2`. `?q=swift` and `?q=rust` remain distinct.

## Eligible signals and exclusions

Accepted public signal kinds are `recommendation`, `share`, `quote`, `reply`, `like`, `repost`, and `publication`. Presentation provenance is deliberately narrower and string-only: `standard_site`, `recommendation`, `direct_share`, `quote`, `repost`, `like`, and `rss`, capped at eight values. Replies contribute to private aggregates but are not presented as provenance.

A candidate is eligible when all of these are true:

- item age is no more than 2,592,000 seconds (30 days);
- source confidence is finite and at least `0.25`;
- it has at least three distinct actors in 24 hours, at least one explicit recommendation in 24 hours, or it is trusted direct Standard Site content published within the last 24 hours (the bounded fresh-content lane);
- the item is marked eligible, not expired, and matches the generation language (unless the bucket is `und`);
- no current `moderation`/`visibility` label has value `block`, `exclude`, `adult`, `graphic`, or `spam`.

Do not ingest private posts, deleted/tombstoned records, blocks/mutes, DMs, raw viewer actions, non-public graph edges, bot/spam traffic identified by labels, or repeated events with the same transport key. That key is derived from environment, source host, cursor kind, and sequence; it deliberately excludes replay source generation. Source-record updates replace older raw signal state and deletes retract only state at or before their event time, so overlapping generation backfills remain idempotent without erasing newer updates. An actor contributes at most once to each distinct-actor window even if they emit several engagement events. Recommendation is an admission signal, not a guarantee of placement.

Retention defaults are code constants in `WireDataPolicy`:

| Data | Retention |
| --- | --- |
| Public signal events | 7 days |
| Applied inbox envelopes | 1 day |
| Dead letters | 14 days |
| Items/presentation snapshots | 30 days since final eligibility |
| Standard Site publication resolver projection | 30 days since last observation/resolution |
| Active actor records | 30 days |
| Follow edges | 30 days |
| Community assignments | 7 days |
| Superseded/shadow generations | 48 hours |

All cleanup is bounded by `WIRE_RETENTION_BATCH_SIZE` (default 5,000). The Database Migrator owns schema changes; runtime services never run migrations.

## Actor hashing, graph bounds, and communities

`WireActorHasher` uses HMAC-SHA256 with at least 256 bits of secret material and emits `h1:<64 lowercase hex characters>`. Input is trimmed and lowercased. Store only this keyed hash for engagement actors in graph, signal, rollup, and community tables; ordinary SHA-256 of a DID is reversible by enumeration and is prohibited. Community keys are also keyed hashes. The sole raw-DID exception is the public source/author DID attached to a public item for attribution and viewer block/mute filtering. Rotate actor hashes by introducing a new prefix/key generation and bounded dual-write; do not overwrite hashes in place.

The active graph is not the social graph archive. Keep at most the 250,000 most recently active actors from the last 30 days and at most the 200 most recently observed public follow edges per actor (`WireDataPolicy.maximumFollowEdgesPerActor`). Recompute deterministic community assignments every six hours using the current bounded graph, with a stable `algorithm_version` and stable tie ordering by hashed key. Assignments expire after seven days so an interrupted clustering job cannot become permanent authority. Serving sees only per-item community spread, never actor or edge rows.

## Exact ranking algorithm (`wire-v1`)

Let `clamp(x) = min(1, max(0, x))`, `age` be nonnegative seconds since `publishedAt` (or `firstSeenAt`), `a24` be distinct sharers in 24 hours, `sh1`/`sh24` be shares in one/24 hours, `l1`/`l24` be likes, `r1`/`r24` be reposts, `la24`/`ra24` be their distinct actor counts, `s7` be all seven-day signals, and `c24` be distinct qualifying communities.

Normalized components:

```text
distinctSharers24h      = clamp(log1p(a24) / log1p(30))
shareVelocity1h         = clamp(sh1 / (max(1, sh24 / 24) * 4))
likeBreadthVelocity     = (clamp(log1p(la24) / log1p(30))
                           + clamp(l1 / (max(1, l24 / 24) * 4))) / 2
repostBreadthVelocity   = (clamp(log1p(ra24) / log1p(30))
                           + clamp(r1 / (max(1, r24 / 24) * 4))) / 2
communitySpread         = clamp(c24 / 5)
freshness               = 0.5 ^ (age / 64,800)
resurfacingAcceleration = clamp(sh1 / (max(1, s7 / 168) * 3))
sourceConfidence        = clamp(sourceConfidence)
```

Score:

```text
0.24 * distinctSharers24h
+ 0.20 * shareVelocity1h
+ 0.08 * likeBreadthVelocity
+ 0.08 * repostBreadthVelocity
+ 0.15 * communitySpread
+ 0.12 * freshness
+ 0.08 * resurfacingAcceleration
+ 0.05 * sourceConfidence
```

The implementation divides by the sum of weights, so validated future configurations remain normalized. Weights must be finite/nonnegative with a positive total. Thresholds/targets and time intervals must be positive and source confidence must stay in `[0, 1]`. Sort by score descending, then `canonicalKey` ascending; input order, database plan, clock locale, and process count must not change output.

### Presentation reasons

Compute every applicable reason, then emit at most two using this priority order:

1. `breaking_story`: published within six hours and one-hour shares are at or above the generation P90.
2. `widely_discussed`: 24-hour distinct sharers are at or above P90.
3. `shared_across_communities`: at least three qualifying communities and spread at or above P75.
4. `fresh_publication`: trusted direct Standard Site publication content within 24 hours.
5. `resurfacing`: at least 48 hours old with current hourly shares at least three times the seven-day hourly baseline.

Reasons are presentation-safe explanations, not raw counts. `WireFeedItem` also caps decoded/constructed reasons at two and provenance at eight. Public DTOs never expose score or internal rank.

## Diversity

Diversity applies to the first 50 items after deterministic score ordering. Greedily accept a candidate unless it would exceed, in this exact check order:

1. four items per source domain;
2. three per publication;
3. two per author;
4. five per topic;
5. ten per dominant active-actor community.

Missing publication/author/community does not consume that dimension. Duplicate topic keys count once. A violating item is deferred and records the first violated dimension. Continue scanning for nonviolating items. If fewer than 40 positions can be filled, relax topic, community, author, publication, then domain caps by one level at a time, recording each relaxation. After the first page, append every unselected item in original score/tie order. Diversity never drops a candidate or changes its score, and safety exclusions never relax.

## Languages and fallback

`und` is the global/default bucket. Every global worker cycle builds it first, then discovers and builds at most 12 observed locale buckets. Global and language-specific generations require at least 200 eligible candidates; a locale must also fill a diverse first page of 50. Language tags are lowercase BCP 47 primary languages, maximum 35 characters. Catalog languages are capped at 12.

Serving behavior:

- return `source: ranked`, `degraded: false` for a fresh active generation in the requested language;
- return `source: stale_generation`, `degraded: true` when the last safe generation is beyond the freshness SLO but not expired;
- fall back to the ranked `und` generation when a requested language has no eligible locale generation;
- after 30 minutes, serve a deterministic diversity-capped recent trusted-content fallback from PostgreSQL; never synthesize or merge a client-side feed.

## Generations and cursors

A generation is immutable after commit. The worker inserts its metadata/items, marks the previous active generation superseded, marks the new generation committed, and moves `wire_feed_state` in one transaction. Concurrent workers serialize on the feed-state row. Shadow generations never move the pointer. The `WIRE_FEED_MODE` rollout values are exactly `off`, `shadow`, `api`, and `visible`, defaulting to `off`. `off` does no generation work. `shadow` builds without a pointer or public route. `api` commits/moves the pointer and serves API responses while the catalog hides navigation (`enabled: true`, `available: false`). `visible` commits/serves and reports catalog navigation enabled/available.

`WireCursorCodec` accepts at least 32 bytes of secret material. Its version-1 payload contains exactly the generation ID, language, and next ordinal; the token is `base64url(payload).base64url(HMAC-SHA256(payload))`. Decode rejects malformed, oversized (>4,096 bytes), invalid-signature, unsupported-version, negative-ordinal, empty/oversized-generation, and empty/oversized-language tokens. Serving must additionally reject a cursor when its language differs from the request or its generation has expired, returning `CursorExpired`. Cursor HMAC secrets are server-only and rotate with an overlap window.

## Moderation, privacy, and presentation

Moderation is fail-closed. Before generation, the worker queries each configured ATProto labeler for exact candidate representative AT-URIs and public source-author DIDs in bounded batches. A fully paginated snapshot atomically projects network takedown, `!hide`, spam, adult/sexual, and graphic-media labels; negations, expiry, and absence remove prior projections. The worker excludes active block/exclude/adult/graphic/spam labels, and the serving adapter repeats that check so an already-generated item can be removed immediately. A failed, incomplete, or stale baseline refresh prevents generation activation and preserves the last good label rows. If viewer moderation state is unavailable, return `ModerationUnavailable`, not an unfiltered edition.

Baseline label trust is currently constrained to a configured HTTPS query endpoint plus exact configured response source DID. The worker does not yet verify the optional label signature against the labeler DID, so this transport-and-attribution check is not independent cryptographic proof of label authenticity. AppView permits the last successful complete baseline for at most 30 minutes; ranked pages, item detail, catalog availability, and simplified fallback all fail closed after that allowance.

`presentation_snapshot` and `provenance` contain only fields approved for the public lexicon. The response shape is `itemId`, `canonicalUrl`, optional `representativeUri`, title/summary/timestamps/image, `source {name, domain, publication?, author?}`, at most two reasons, and at most eight provenance kinds. `WirePage` adds generation/time/language, a signed cursor, `ranked|stale_generation|simplified_fallback`, and `degraded`. `WireFeedCatalog` is one object whose default title is exactly **The Wire** and subtitle is exactly **Important stories across the social web**.

`viewerDid` exists on `WireFeedStore` only for uniform auth/moderation policy. Ranking must not use it. Public source/author DIDs may be retained only for item attribution and viewer filtering and must expire with the rebuildable item projection. DIDs for sharers and other engagement actors remain HMAC-only. Never log cursor secrets, raw DIDs, raw community membership, viewer identity joined to item identity, or full query payloads. Aggregate diagnostics must enforce minimum cohort sizes before export.

## Authority and cache boundary

PostgreSQL is authoritative for the inbox, items/aliases, short-retention signals, bounded graph, labels, rollups, generations, ranked items, and active pointer. Tables are rebuildable projections of public records, but are still durable operational state during a rollout. Redis is optional and may cache only a fully committed generation. It cannot choose an active generation, extend retention, bypass moderation, or keep serving after PostgreSQL declares a generation expired.

## Configuration and validation

Ranking defaults live in `WireRankingConfig`/`WireRankingWeights`/`WireDiversityPolicy` and are identified by `wire-v1`. Operational environment controls are:

- `WIRE_FEED_MODE=off|shadow|api|visible`;
- `WIRE_RANK_INTERVAL_SECONDS=300`;
- `WIRE_CANDIDATE_LIMIT=5000`;
- `WIRE_GENERATION_RETENTION_SECONDS=172800`;
- `WIRE_RETENTION_BATCH_SIZE=5000`;
- `WIRE_LANGUAGE_BUCKET=und`;
- `WIRE_ACTOR_HMAC_SECRET` with at least 32 bytes outside `off` mode.
- `WIRE_BASELINE_LABELERS` as comma-separated `source-did|https://labeler-host` authorities (default: Bluesky Moderation Service);
- `WIRE_LABEL_REFRESH_MAX_AGE_SECONDS=900`.
- `WIRE_INBOX_BATCH_SIZE=1000`, `WIRE_INBOX_CONCURRENCY=16`, and `WIRE_INBOX_IDLE_MILLISECONDS=250`;
- `WIRE_POSTGRES_MAX_CONNECTIONS=12`.

`DATABASE_URL` is always required. Positive integers reject zero/negative/garbage. Unknown modes fail startup. Ranking weights are not mutable ad-hoc environment variables in this slice: changing them requires a reviewed, versioned config/code deployment, replay evidence, README update, and a new version when ordering semantics change.

## Observability and rollout SLOs

Emit privacy-safe metrics/logs for inbox pending/leased/dead-letter counts and oldest age; signal/rollup freshness; eligible/rejected counts by reason; generation duration/count/version/mode; diversity deferral count/dimension; active generation age; cursor failure category; moderation exclusions; fallback/stale responses; and PostgreSQL/optional-Redis latency/error rates. Generation IDs and canonical keys are allowed operational identifiers; actor/community hashes are not log fields.

Initial gates:

- active generation age below ten minutes;
- generation duration below 60 seconds and below the configured interval;
- inbox oldest actionable age <= 120 seconds;
- zero unsigned/invalid-signature cursors accepted;
- zero score/rank/raw actor/community fields in public responses;
- 99.9% successful generation cycles over the observation window before promotion.

Alert separately on ingestion freshness, rollup freshness, generation freshness, moderation availability, and serving availability. A healthy HTTP process is not proof that The Wire is current.

## Testing, replay, promotion, and rollback

Required deterministic fixtures cover URL aliases and semantic query separation; HMAC cursor round-trip/tamper/wrong-key/limits; score ordering and canonical-key ties; every eligibility rejection; exact reason thresholds/priority/caps; each diversity dimension plus underfill relaxation; locale eligibility/fallback; moderation removal after generation; atomic pointer movement/concurrent workers; retention batches; privacy-safe DTO encoding; and PostgreSQL integration against a disposable database.

Replay a fixed, time-bounded input corpus with a fixed `asOf`, hashing the ordered `(canonicalKey, reasons)` output. Compare current vs candidate versions for overlap, source/domain/author/topic concentration, language coverage, label exclusions, and reason distribution. No production identities should appear in exported replay artifacts.

Promotion is `off` -> Development `shadow` -> reviewed replay/metrics -> Development `api` -> authenticated and anonymous acceptance -> Development `visible` -> explicit Production approval. Roll back immediately to `api`, `shadow`, or `off` according to the failing surface, or atomically restore a still-valid previous generation pointer. Do not delete generations during rollback. Database migrations are forward-only and provider-neutral PostgreSQL; Redis deletion is never a rollback mechanism.

### Worked ranking example

At `asOf`, a six-hour-old story with 15 distinct 24-hour sharers, eight shares in the last hour, 16 shares in 24 hours, four communities, and source confidence `0.8` has these representative primary components:

```text
distinctSharers24h = log1p(15) / log1p(30) ~= 0.807
shareVelocity1h    = clamp(8/(max(1,16/24)*4)) = 1
communitySpread    = clamp(4/5) = 0.8
freshness          = 0.5^(21,600/64,800) ~= 0.794
sourceConfidence   = 0.8
```

Like, repost, and resurfacing components depend on their separate rollups and are added with their exact weights above. Percentile reason thresholds depend on the generation corpus; the public response contains at most the first two applicable reasons by priority. If the story's domain already occupies four first-page positions, it is deferred while the algorithm looks for a nonviolating story, then reintroduced only through the recorded relaxation rules.
