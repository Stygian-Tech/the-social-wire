# The Wire

**The Wire** — **Important stories across the social web** — is The Social Wire's global, non-personalized edition of important public stories. This document is the algorithm and data-contract source of truth for `WireCore`, the independent `wire-worker`, ingestion producers, and serving adapters. A behavior change is incomplete until code, tests, configuration version, and this document change together.

## End-to-end flow

1. Public Jetstream/RSS producers place idempotent projection-bearing envelopes in `wire_ingestion_inbox`. Wire-global Jetstream preparation advances its fenced checkpoint without staging identity/sync, active-account, or linkless Bluesky post-create no-ops. It retains inactive-account cleanup plus every post update/delete needed to retract older linked state. The bounded inbox owns retry, lease, dead-letter, and expiry state during normal operation; after a PostgreSQL crash, the fenced producer rebuilds it from a logged provider cursor.
2. A dedicated drain runtime continuously claims bounded inbox batches, applies different repositories concurrently while preserving repository FIFO, and uses bounded idle/error backoff. Claims order ready work by retry time before sequence so retries in one repository cannot starve unrelated pending repositories. The applier canonicalizes the linked story, upserts `wire_items` plus `wire_item_aliases`, records presentation-safe provenance, applies moderation/source labels, and inserts a deduplicated `wire_signal_events` row. Standard Site publication records form a rebuildable PostgreSQL resolver projection; documents carrying a publication AT-URI plus relative path use that projection or a bounded public PLC/PDS lookup. PLC/PDS DNS is revalidated immediately before every request, mixed or non-global answer sets fail closed, and redirects are not followed. Unresolved dependencies retry for no more than 24 hours.
3. The applier updates bounded, keyed-hash graph state (`wire_active_actors`, `wire_follow_edges`, `wire_actor_communities`) and privacy-safe aggregate counts in `wire_signal_rollups`. DIDs for sharers, likers, reposters, and other engagement actors never enter a serving row. A public source/author DID may be retained only with its public item for attribution and viewer block/mute filtering; it is never a ranking feature or community identifier.
4. Every five minutes by default, `wire-worker` prunes bounded graph state, refreshes community assignments when due, rebuilds exact rollups, refreshes baseline labels, loads eligible item/rollup/metadata rows, computes the deterministic `wire-v4` score, applies first-page diversity, and writes an immutable `wire_rank_generations` plus its `wire_ranked_items`. Continuous archive draining never increases labeler cadence.
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

Accepted public conversation signal kinds are `recommendation`, `share`, `quote`, `reply`, `like`, `repost`, and `publication`. Viewer-authored `app.thesocialwire.wireFeedback` records are projected separately as `good` or `not_good` article-quality assessments. Presentation provenance is deliberately narrower and string-only: `standard_site`, `recommendation`, `direct_share`, `quote`, `repost`, `like`, and `rss`, capped at eight values. Feedback and replies contribute only to private aggregates and are never presented as provenance or public reasons.

A candidate is eligible when all of these are true:

- item age is no more than 2,592,000 seconds (30 days);
- source confidence is finite and at least `0.25`;
- it has at least five distinct high-intent actors in 24 hours or two explicit recommendations in 24 hours; a trusted Standard Site story published within 72 hours has a bounded lane at three distinct high-intent actors;
- the item is marked eligible, not expired, and matches the generation language (unless the bucket is `und`);
- no current `moderation`/`visibility` label has value `block`, `exclude`, `adult`, `graphic`, or `spam`.

Do not ingest private posts, deleted/tombstoned records, blocks/mutes, DMs, non-public graph edges, bot/spam traffic identified by labels, or repeated events with the same transport key. That key is derived from environment, source host, cursor kind, and sequence; it deliberately excludes replay source generation. Source-record updates replace older raw signal state and deletes retract only state at or before their event time, so overlapping generation backfills remain idempotent without erasing newer updates. An actor contributes at most once to each distinct-actor window even if they emit several engagement events. Recommendations are counted by distinct HMAC actor, so duplicate recommendation records from one account cannot satisfy the recommendation floor. High-intent actors are the distinct actors behind a share, quote, recommendation, or direct publication event; passive likes, reposts, replies, and Social Wire article feedback cannot admit a story on their own. Recommendation is an admission signal, not a guarantee of placement.

Wire feedback is a public, viewer-owned PDS record with a deterministic per-URL key. The worker stores only the canonical story key, keyed actor hash, record URI, value, and expiring timestamps in `wire_article_feedback`; the raw viewer DID never enters PostgreSQL. One viewer contributes at most one current assessment per story, updates replace the earlier value, deletes retract it, and rows expire after seven days. Positive feedback is a bounded ranking boost and negative feedback a bounded penalty after a story has independently passed admission. Neither can create a candidate, satisfy admission, alter moderation, or leak through Wire/Corpus Edge responses. This separation limits brigading impact while still letting readers tune article quality.

To keep a sparse edition useful, `wire-v4` has a deterministic reserve. When the strict pool has fewer than 50 stories, candidates meeting the former three-high-intent-actor or one-recommendation floor may fill only the missing positions. The quality reserve takes usable Standard Site/OpenGraph-backed candidates first, then a general reserve. Metadata and feedback never admit an article by themselves, and reserve stories never displace strict stories.

Retention defaults are code constants in `WireDataPolicy`:

| Data | Retention |
| --- | --- |
| Public signal events | 7 days |
| Article-quality feedback projection | 7 days |
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

## Exact ranking algorithm (`wire-v4`)

Let `clamp(x) = min(1, max(0, x))`, `age` be nonnegative seconds since `publishedAt` (or `firstSeenAt`), `sh1`/`sh24` be distinct high-intent actors in one/24 hours, `l1`/`l24` be likes, `r1`/`r24` be reposts, `la24`/`ra24` be their distinct actor counts, `rec24` be distinct Standard Site recommenders, `good24`/`bad24` be distinct Social Wire assessments, `s7` be all seven-day signals, and `c24` be distinct qualifying communities. `standardSiteAuthority` is one only for authoritative `standard_site` provenance. `openGraphMetadata` is one only while a successful OpenGraph cache row remains fresh or stale-safe and contains at least two useful presentation fields.

Normalized components:

```text
distinctSharers24h      = clamp(log1p(sh24) / log1p(30))
shareVelocity1h         = clamp(sh1 / (max(1, sh24 / 24) * 4))
likeBreadthVelocity     = (clamp(log1p(la24) / log1p(30))
                           + clamp(l1 / (max(1, l24 / 24) * 4))) / 2
repostBreadthVelocity   = (clamp(log1p(ra24) / log1p(30))
                           + clamp(r1 / (max(1, r24 / 24) * 4))) / 2
communitySpread         = clamp(c24 / 5)
freshness               = 0.5 ^ (age / 36,000)
resurfacingAcceleration = clamp(sh1 / (max(1, s7 / 168) * 3))
sourceConfidence        = clamp(sourceConfidence)
standardSiteAuthority   = isStandardSite ? 1 : 0
openGraphMetadata       = hasUsableOpenGraphMetadata ? 1 : 0
recommendationBreadth   = clamp(log1p(rec24) / log1p(10))
positiveFeedbackBreadth = clamp(log1p(good24) / log1p(10))
negativeFeedbackBreadth = clamp(log1p(bad24) / log1p(10))
```

Score:

```text
0.22 * distinctSharers24h
+ 0.10 * shareVelocity1h
+ 0.02 * likeBreadthVelocity
+ 0.02 * repostBreadthVelocity
+ 0.14 * communitySpread
+ 0.18 * freshness
+ 0.06 * resurfacingAcceleration
+ 0.08 * sourceConfidence
+ 0.11 * standardSiteAuthority
+ 0.05 * openGraphMetadata
+ 0.10 * recommendationBreadth
+ 0.06 * positiveFeedbackBreadth
```

The implementation divides that positive score by the sum of positive weights, so validated future configurations remain normalized. It then subtracts `0.10 * negativeFeedbackBreadth` and the matching platform-destination penalty. After admission, it adds a deterministic nudge in `[0, 0.005]` derived from FNV-1a over the canonical key and `floor(asOf / 1,800 seconds)`, then clamps the result to `[0, 1]`. The nudge is stable across every five-minute generation within a 30-minute bucket and changes only at a bucket boundary. Primary, quality-reserve, and general-reserve tiers are nudged and sorted separately, so rotation cannot admit a story or move reserve filler ahead of a strict story. A half-point maximum permits nearly tied eligible stories to rotate without overwhelming material quality differences.

Standard Site authority (`0.11`) and Standard Site recommendation breadth (`0.10`) therefore have larger explicit coefficients than Social Wire positive feedback (`0.06`) and a Bluesky like (`0.02`); recommendations also participate in high-intent breadth and admission by design. The positive-weight total remains `1.14`, so the increased freshness, Standard Site, and recommendation emphasis does not silently dilute those authority signals. Weights must be finite/nonnegative with a positive total. Thresholds/targets and time intervals must be positive and source confidence must stay in `[0, 1]`. Sort each admission tier by nudged score descending, then `canonicalKey` ascending; input order, database plan, clock locale, and process count must not change output.

Platform-hosted/social-media destinations remain eligible but receive a bounded score subtraction because they are less likely to be the original publication. Matching is exact-host or dot-suffix only, so `news.youtube.com` matches while `notyoutube.com` does not. Defaults are `0.06` for `youtube.com`, `youtu.be`, and `twitch.tv`; `0.04` for `reddit.com` and `redd.it`; and `0.05` for `bsky.app`, `facebook.com`, `fb.com`, `fb.watch`, `instagram.com`, `linkedin.com`, `pinterest.com`, `threads.net`, `tiktok.com`, `twitter.com`, and `x.com`. The longest matching suffix wins. Each configured penalty must be finite and in `[0, 0.20]`. Penalties affect ordering only: they never change admission tier, exclude a story, or weaken moderation. A strong independently qualified story can still rank.

### Presentation reasons

Compute every applicable reason, then emit at most two using this priority order:

1. `breaking_story`: published within six hours and one-hour shares are at or above the generation P90.
2. `widely_discussed`: 24-hour distinct sharers are at or above P90.
3. `shared_across_communities`: at least three qualifying communities and spread at or above P75.
4. `fresh_publication`: trusted direct Standard Site publication content within 72 hours.
5. `resurfacing`: at least 48 hours old with current hourly shares at least three times the seven-day hourly baseline.

Reasons are presentation-safe explanations, not raw counts. `WireFeedItem` also caps decoded/constructed reasons at two and provenance at eight. Public DTOs never expose score or internal rank.

## Diversity

Domain penalties apply before deterministic score ordering; diversity then applies to the first 50 items. Greedily accept a candidate unless it would exceed, in this exact check order:

1. four items per source domain;
2. three per publication;
3. two per author;
4. five per topic;
5. ten per dominant active-actor community.

Missing publication/author/community does not consume that dimension. Duplicate topic keys count once. A violating item is deferred and records the first violated dimension. Continue scanning for nonviolating items. If fewer than 40 positions can be filled, relax topic, community, author, publication, then domain caps by one level at a time, recording each relaxation. After the first page, append every unselected item in original score/tie order. Diversity never drops a candidate or changes its score, and safety exclusions never relax.

## News edition assembly (`wire-edition-v2`)

`wire-v4` remains the sole authority for story eligibility and order. `wire-edition-v2`
is a deterministic presentation pass over that already-ranked order; it never changes a
story score, exposes a score/rank, or creates a personalized order. Duplicate item IDs
are removed by first occurrence before assembly.

The edition allocates primary story modules in this order:

1. Select up to four lead stories—one feature and three supporting stories—accepting only
   the first story from each normalized source domain. If those four contain no direct
   `site.standard.document` or `site.standard.entry`, the final supporting slot goes to the
   best such story within the canonical top ten when doing so preserves source diversity.
   The feature and first two supporting stories never move. This is a bounded presentation
   tie-break; it does not alter `wire-v4` scores, eligibility, or continuation order.
2. From the unallocated stories, select up to six publication panels in first-appearance
   order. A panel requires at least two remaining stories and contains at most three.
   Publication identity prefers the presentation-safe publication key, then publication
   URI, then normalized source domain.
3. From the unallocated stories, build at most three stable editorial rails in this order:
   **Breaking & Developing** (`breaking-developing`) accepts `breaking_story` or
   `widely_discussed`; **Across Communities** (`across-communities`) accepts
   `shared_across_communities`; **Resurfacing** (`resurfacing`) accepts `resurfacing`.
   Hide a rail with fewer than four stories and cap each visible rail at ten.
4. Put every still-unallocated first-page story in the general remainder, preserving rank
   order. `fresh_publication` remains a presentation reason on its story and does not create
   a separate rail.

A story appears in exactly one primary module. The secondary trending list deliberately
may repeat a primary story: it takes breaking or widely-discussed stories first in their
existing rank order, fills from the remaining rank order, and caps at ten. All edition
arrays and panels carry presentation DTOs only; internal score and ordinal fields are not
encoded.

Talked-about accounts are public subjects of discussion, never the private identities of
sharers, likers, or reposters. An account qualifies only after appearing across at least
two distinct stories and three distinct HMAC-counted public speakers. Qualifying accounts
sort by distinct-story breadth, distinct-speaker breadth, best associated story rank,
latest mention time, then normalized DID, and cap at ten. Aggregate counts and associated
story rank are assembler inputs only and are not Codable response fields. Materialization
considers only mention edges attached to the first 50 displayed stories, keeping the rail
connected to the edition rather than unrelated retained corpus items.

Mention edges come only from explicit `app.bsky.richtext.facet#mention` DIDs and quoted
record subjects on public source posts. Authors, sharers, likers, and reposters do not
become discussed accounts unless the same post explicitly mentions or quotes them. A
source-post deletion retracts its mention edges through the deletion event time, and every
edge expires with the seven-day signal retention window. Public profile snapshots are
refreshed asynchronously, expire after 24 hours, and pass baseline moderation before
materialization. AppView applies viewer moderation again and hides the entire people rail
unless at least four safe profiles remain.

Article presentation follows one explicit precedence: authoritative Standard Site record,
fresh page OpenGraph/Twitter metadata, embedded Bluesky external card, then social-post
text and hostname fallback. Precedence is applied per field, so lower-priority page
metadata may fill a missing Standard Site thumbnail, byline, publication timestamp, icon,
or description but cannot replace an authoritative non-empty value. The selected fields
include bounded Schema.org JSON-LD article fallbacks after explicit OpenGraph/Twitter tags,
which recovers publisher names, authors, dates, logos, and images from sites that omit OG.
These fields are copied into the item presentation snapshot; browser clients never scrape
or fetch metadata per card. `wire_link_metadata_cache`
keeps successful page metadata fresh for 24 hours and stale-safe for at most seven days,
uses ETag/Last-Modified conditional refreshes, and negative-caches unusable pages for six
hours. Fetches accept HTML only, cap response bodies at 512 KiB, use bounded request time,
follow at most three redirects, and revalidate public DNS on every hop; private, loopback,
link-local, credential-bearing, and non-HTTPS destinations fail closed. A refresh failure
may retain an unexpired stale presentation but never replaces authoritative Standard Site
fields. Ranking receives only a bounded availability bit for a usable, non-expired
OpenGraph cache result. It never receives page text, and OpenGraph cannot satisfy admission.

`WireEdition` is bound to the same generation, language, source/degraded state, and signed
continuation cursor as the underlying ranked page. Publication presentation includes a
stable key, name, domain, optional homepage, and optional icon URL so clients do not need
to reconstruct identity or scrape page metadata.

## Languages and fallback

`und` is the global/default bucket. Every global worker cycle builds it first, then discovers and builds at most 12 observed locale buckets. Global and language-specific generations require at least 50 eligible candidates, exactly the complete diverse first-page target. Language tags are lowercase BCP 47 primary languages, maximum 35 characters. Catalog languages are capped at 12.

Serving behavior:

- return `source: ranked`, `degraded: false` for a fresh active generation in the requested language;
- return `source: stale_generation`, `degraded: true` when the last safe generation is beyond the freshness SLO but not expired;
- fall back to the ranked `und` generation when a requested language has no eligible locale generation;
- keep serving the last active quality generation as stale until its retention expiry rather than replacing it with a looser recency feed;
- when no retained generation exists, serve a deterministic engagement-gated quality fallback that prefers Standard Site stories and requires trusted provenance, usable OpenGraph metadata, or high source confidence; never synthesize or merge a client-side feed.

The simplified fallback is not numerically ranked and therefore does not apply feedback or platform-domain score adjustments. It preserves the same engagement admission floor and deterministic Standard Site/metadata/source-confidence preference without exposing any internal count. A retained ranked generation is always preferred, even when stale.

### Regional presentation relevance

The canonical generation remains language-scoped and country-neutral. When the browser's
first usable BCP 47 language tag includes an explicit non-US region, the web client sends
only the coarse `region=outside-us` hint. It does not send the exact locale or country. US
and regionless/ambiguous language tags send no region hint and preserve canonical order.

For `outside-us`, the worker materializes a second module set from the same admitted first 50
stories. It applies a stable three-position penalty only when authoritative publisher tags
explicitly identify US politics (for example `us-politics`, or separate `united-states` and
`politics` tags). Stories marked Breaking, Widely Discussed, or Across Communities are exempt
so globally important reporting keeps its canonical position. Headline text, domains, IP,
timezone, DID, and raw browser locales do not participate.

The adjustment never removes a story, changes admission, mutates the generation or
continuation cursor, exposes topic tags or a score, or affects US/unknown viewers. Corpus Edge
selects the regional materialization and falls back to canonical modules for older
generations. The coarse region is part of the edition cache key and ETag so cached ordering
cannot cross presentation variants. Continuation pages retain canonical generation order.

## Generations and cursors

A generation is immutable after commit. The worker inserts its metadata/items, marks the previous active generation superseded, marks the new generation committed, and moves `wire_feed_state` in one transaction. Concurrent workers serialize on the feed-state row. Shadow generations never move the pointer. The `WIRE_FEED_MODE` rollout values are exactly `off`, `shadow`, `api`, and `visible`, defaulting to `off`. `off` does no generation work. `shadow` builds without a pointer or public route. `api` commits/moves the pointer and serves API responses while the catalog hides navigation (`enabled: true`, `available: false`). `visible` commits/serves and reports catalog navigation enabled/available.

`WireCursorCodec` accepts at least 32 bytes of secret material. Its version-1 payload contains exactly the generation ID, language, and next ordinal; the token is `base64url(payload).base64url(HMAC-SHA256(payload))`. Decode rejects malformed, oversized (>4,096 bytes), invalid-signature, unsupported-version, negative-ordinal, empty/oversized-generation, and empty/oversized-language tokens. Serving must additionally reject a cursor when its language differs from the request or its generation has expired, returning `CursorExpired`. Cursor HMAC secrets are server-only and rotate with an overlap window.

## Moderation, privacy, and presentation

Moderation is fail-closed. Before generation, the worker queries each configured ATProto labeler for exact candidate representative AT-URIs and public source-author DIDs in bounded batches. A fully paginated snapshot atomically projects network takedown, `!hide`, spam, adult/sexual, and graphic-media labels; negations, expiry, and absence remove prior projections. The worker excludes active block/exclude/adult/graphic/spam labels, and the serving adapter repeats that check so an already-generated item can be removed immediately. A failed, incomplete, or stale baseline refresh prevents generation activation and preserves the last good label rows. If viewer moderation state is unavailable, return `ModerationUnavailable`, not an unfiltered edition.

Baseline label trust is currently constrained to a configured HTTPS query endpoint plus exact configured response source DID. The worker does not yet verify the optional label signature against the labeler DID, so this transport-and-attribution check is not independent cryptographic proof of label authenticity. AppView permits the last successful complete baseline for at most 30 minutes; ranked pages, item detail, catalog availability, and simplified fallback all fail closed after that allowance.

`presentation_snapshot` and `provenance` contain only fields approved for the public lexicon. The response shape is `itemId`, `canonicalUrl`, optional `representativeUri`, title/summary/timestamps/image, `source {name, domain, publication?, author?}`, at most two reasons, and at most eight provenance kinds. `WirePage` adds generation/time/language, a signed cursor, `ranked|stale_generation|simplified_fallback`, and `degraded`. `WireFeedCatalog` is one object whose default title is exactly **The Wire** and subtitle is exactly **Important stories across the social web**.

`viewerDid` exists on `WireFeedStore` only for uniform auth/moderation policy. Ranking must not use it. Public source/author DIDs may be retained only for item attribution and viewer filtering and must expire with the rebuildable item projection. DIDs for sharers and other engagement actors remain HMAC-only. Never log cursor secrets, raw DIDs, raw community membership, viewer identity joined to item identity, or full query payloads. Aggregate diagnostics must enforce minimum cohort sizes before export.

## Authority and cache boundary

PostgreSQL is authoritative for the current projection. The inbox, short-retention signals, graph, and rollups are UNLOGGED and rebuildable from a bounded provider replay; items/aliases, labels, generations, ranked items, editions, and the active pointer remain LOGGED so the last committed edition survives recovery. Redis is optional and may cache only a fully committed generation. It cannot choose an active generation, extend retention, bypass moderation, or keep serving after PostgreSQL declares a generation expired.

## Configuration and validation

Ranking defaults live in `WireRankingConfig`/`WireRankingWeights`/`WireDiversityPolicy` and are identified by `wire-v2`. Operational environment controls are:

- `WIRE_FEED_MODE=off|shadow|api|visible`;
- `WIRE_WORKER_ROLE=combined|rank|drain` (rank owns generation plus metadata/profile
  enrichment and may own terminal cleanup; drain owns scalable inbox work; combined owns both);
- `WIRE_INBOX_CLEANUP_ENABLED=true|false` (assign terminal-row cleanup to exactly one selected role);
- `WIRE_RANK_INTERVAL_SECONDS=300`;
- `WIRE_CANDIDATE_LIMIT=5000`;
- `WIRE_GENERATION_RETENTION_SECONDS=172800`;
- `WIRE_RETENTION_BATCH_SIZE=5000`;
- `WIRE_LANGUAGE_BUCKET=und`;
- `WIRE_ACTOR_HMAC_SECRET` with at least 32 bytes outside `off` mode.
- `WIRE_BASELINE_LABELERS` as comma-separated `source-did|https://labeler-host` authorities (default: Bluesky Moderation Service);
- `WIRE_LABEL_REFRESH_MAX_AGE_SECONDS=900`.
- `WIRE_INBOX_BATCH_SIZE=1000`, `WIRE_INBOX_CONCURRENCY=16`, and `WIRE_INBOX_IDLE_MILLISECONDS=250`;
- producer `WIRE_ADMISSION_RATE_PER_SECOND` is required for Wire-global ingress and
  must not exceed a measured sustained drain rate after operational headroom;
  `WIRE_ADMISSION_BURST_EVENTS=1` bounds each token-bucket staging transaction;
- `WIRE_METADATA_BATCH_SIZE=32`, `WIRE_METADATA_CONCURRENCY=8`, and `WIRE_METADATA_IDLE_MILLISECONDS=1000`;
- `WIRE_POSTGRES_MAX_CONNECTIONS=12`.

`DATABASE_URL` is always required. Positive integers reject zero/negative/garbage. Unknown modes fail startup. Ranking weights are not mutable ad-hoc environment variables in this slice: changing them requires a reviewed, versioned config/code deployment, replay evidence, README update, and a new version when ordering semantics change.

## Observability and rollout SLOs

Emit privacy-safe metrics/logs for inbox pending/leased/dead-letter counts and oldest age; signal/rollup freshness; eligible/rejected counts by reason; generation duration/count/version/mode; diversity deferral count/dimension; active generation age; cursor failure category; moderation exclusions; fallback/stale responses; and PostgreSQL/optional-Redis latency/error rates. Generation IDs and canonical keys are allowed operational identifiers; actor/community hashes are not log fields.

The news edition additionally reports metadata cache hit/stale/miss/failure age, edition
assembly duration, section fill and underfill, publication concentration, eligible people
count/profile freshness, and `getWireEdition` latency. These measurements may include a
generation ID or aggregate module key, but never a raw DID, actor/community hash, internal
score, rank, speaker count, or viewer-to-story join.

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
freshness          = 0.5^(21,600/36,000) ~= 0.660
sourceConfidence   = 0.8
```

Like, repost, and resurfacing components depend on their separate rollups and are added with their exact weights above. Percentile reason thresholds depend on the generation corpus; the public response contains at most the first two applicable reasons by priority. If the story's domain already occupies four first-page positions, it is deferred while the algorithm looks for a nonviolating story, then reintroduced only through the recorded relaxation rules.
