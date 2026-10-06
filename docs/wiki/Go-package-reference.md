# Go package reference

This reference describes the repository-local Go foundation on `dev`. It is migration work in progress, not a claim that the Swift workers have been replaced. Each source file below has inline purpose/contract comments; package READMEs explain caller responsibilities and verification. See [[Go-ingestion-and-ranking]] and [[Go-verification-and-deployment]].

## financecore

Supply eligible ArticleAnalysis from the canonical resolver. Ranking personalizes an existing base score and does not mutate it. Instrument boost is 0.25, sector boost 0.10, total capped at 0.35; materiality is multiplicative. Six-hour coverage suppression requires a normalized headline of at least twenty characters and a publication date. Global reservation uses every fifth slot when an eligible major-global candidate remains.

| Source | Responsibility |
| --- | --- |
| `financecore/identity.go` | Derives stable instrument and PDS selection identifiers from provider-native identity, then fingerprints sorted, deduplicated preferences. Display names and input order cannot change these keys. |
| `financecore/models.go` | Defines the evidence and candidate shapes consumed by Finance ranking. These are analysis inputs, not an article resolver or a reviewed instrument catalog. |
| `financecore/ranker.go` | Filters ineligible/nonfinite candidates, applies materiality and capped preference boosts, breaks ties by item ID, and suppresses duplicate URLs and six-hour headline/entity coverage. Optional global slots are filled from remaining candidates by base score. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/financecore/README.md).

Migration boundary: partial. Remaining: article resolver and topic evidence; reviewed catalogs and named feeds; provider adapters and rights constraints; cursors and remaining serving models.

## gatewaycore

DecodePayload uses UnsafePayloadWithoutVerification deliberately for inspection. No route may use successful decoding as authorization. Issuer binding, signatures, DPoP, replay checks, and internal Gateway/AppView trust remain outside this implementation. DNS admission must be coupled to pinned-address dialing and redirect revalidation.

| Source | Responsibility |
| --- | --- |
| `gatewaycore/compact_jwt.go` | Uses go-jose to parse a signed compact envelope without verifying its signature. Payloads remain raw JSON to preserve exact numbers. ATH hashing is a DPoP helper; neither operation authenticates the caller. |
| `gatewaycore/public_dns.go` | Bounds concurrent DNS admission and rejects an HTTPS endpoint if any answer is special-use or private. Address selection is deterministic. Callers must pin the admitted address when dialing and revalidate redirects to avoid DNS rebinding. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/gatewaycore/README.md).

Migration boundary: partial. Remaining: issuer-bound OAuth and DPoP verification adapters; gateway/appview internal trust; repo discovery and PDS clients; OAuth metadata and remaining service contracts.

## internal/signedcursor

Only packages within this module may import this internal codec. The constructor requires at least 32 secret bytes and copies them. Decode bounds encoded input to 4,096 characters, rejects alternate base64url spellings, and verifies HMAC before JSON decoding. Public wrappers remain responsible for versions, required fields, viewer binding, and expiry.

| Source | Responsibility |
| --- | --- |
| `internal/signedcursor/codec.go` | Provides the shared HMAC-SHA256 cursor envelope: unpadded base64url JSON plus an authenticated signature. Secrets are copied, signatures compared in constant time, and noncanonical encodings rejected. Public cursor wrappers enforce domain-specific fields. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/internal/signedcursor/README.md).

## lexicons

Regenerate bundles from packages/lexicons JSON. Documents and Resolve return independent decoded/copied data, protecting the embedded registry from caller mutation. Lookup is not Lexicon value validation; do not replace the existing validator with schema existence checks.

| Source | Responsibility |
| --- | --- |
| `lexicons/registry.go` | Loads independent copies of canonical Lexicon documents and resolves default, named, or relative definitions. Schema lookup does not validate a record against the schema; typed models and value validation remain migration work. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/lexicons/README.md).

Migration boundary: partial. Remaining: typed generated models; Lexicon value validation and format conformance.

## operationscore

Reserve a separate control connection budget from workload/publication capacity. Operations must honor context cancellation and return after cleanup; the supervisor intentionally waits for them before release. OnEvent may run concurrently and must not block. Validate alone does not protect later writes: LockRoleLeaseFence belongs inside the transaction performing those writes.

| Source | Responsibility |
| --- | --- |
| `operationscore/lease.go` | Defines role ownership as environment, role, owner ID, and monotonically changing fencing token. Configuration reserves five seconds of lease safety margin; ownership work must carry this authority into its publication transaction. |
| `operationscore/lease_supervisor.go` | Runs acquisition/standby and, while owned, coordinates workload, periodic renewal, and an independent expiry watchdog. Any completion cancels all owned work; joining precedes bounded release, so an old worker cannot keep publishing after reacquisition. |
| `operationscore/postgres_role_lease_store.go` | Uses PostgreSQL time and row locks to acquire, renew, validate, and release roles. A live same-owner acquisition retains its token; takeover advances it. Shared publication fences permit expiry-only renewal while excluding authority revocation. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/operationscore/README.md).

Migration boundary: partial. Remaining: health evidence and telemetry; recovery/control/store contracts; remaining supported stores; supervisor retry and observation policy parity.

## readstate

Use aliases when callers need the implemented shared protocol without a second copy of its model definitions. Storage, repository traversal, sync, outbox, compaction, and garbage collection are still absent; do not infer completeness from this facade.

| Source | Responsibility |
| --- | --- |
| `readstate/protocol.go` | Re-exports the implemented ReadStateCore protocol surfaces using aliases, preserving type identity across imports. This facade provides no repository, outbox, persistence, sync, or garbage collector. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/readstate/README.md).

Migration boundary: partial. Remaining: repository/outbox/GC and persistence contracts; remaining TypeScript protocol conformance cases.

## readstatecore

Use json.Decoder.UseNumber for untrusted canonical values; float64 is deliberately unsupported. MaximumSequence is 2^53−1, portable JSON records are at most 65,536 bytes, canonical construction/output at most 16 MiB, and nesting at most 32. These separate limits serve different operations. Nil selector slices preserve absence; an empty slice is not interchangeable with omitted selectors. Projection owns clones and returns clones. Receipt acknowledgements prove contiguous pending intents, not transport delivery or identity authentication.

| Source | Responsibility |
| --- | --- |
| `readstatecore/models.go` | Defines portable v1/v2 manifest, operation, boundary, and resolution fields with canonical JSON names. Pointers and nil slices preserve absent-field distinctions. Sequences are bounded to the interoperable JavaScript safe-integer maximum. |
| `readstatecore/validation.go` | Checks timestamps, viewer-owned chunk references, selector exclusivity, record sizes, and version-specific manifest invariants. These checks cover the implemented models; they are not a strict closed-shape v2 loader and do not verify remote CID contents. |
| `readstatecore/projection.go` | Builds an immutable indexed snapshot from validated operations. Resolution selects the greatest applicable sequence across exact subjects and author/site boundaries; timestamp equality uses the boundary entry ID as an inclusive tie-break. |
| `readstatecore/canonical_buffer.go` | Stops encoded DAG-CBOR growth at 16 MiB even when the upstream codec writes incrementally. This hashing bound is separate from the 64 KiB portable-record JSON bound. |
| `readstatecore/canonical_hash.go` | Assembles the restricted receipt value model into IPLD nodes and delegates canonical DAG-CBOR ordering/encoding to go-ipld-prime. Construction and output are bounded; floats, bytes, links, unsupported types, unsafe integers, and invalid UTF-8 are rejected. |
| `readstatecore/intent_hash.go` | Hashes a logical action independently of assigned sequence. Split parts must agree on action metadata; exact subjects and boundary selectors are deduplicated and sorted before a v2 domain-separated canonical hash is computed. |
| `readstatecore/device_receipt.go` | Chains contiguous device counters and original-intent hashes with domain separation. A remote acknowledgement is accepted only if recomputing the proposed prefix from locally pending intents yields the same counter and hash. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/readstatecore/README.md).

Migration boundary: partial. Remaining: strict v2 closed-shape loading; v1 extension retention; v2 merge/compaction and manifest publication; sync/store/transport/GC implementations.

## socialwireredis

Use NewCacheClient with RedisCommands backed by a caller-owned go-redis client. Configure TLS, command deadlines, retries, pool sizing, and Close at the service boundary. Treat ErrCircuitOpen/transport errors as optional-cache failure and choose durable fallback explicitly. Millisecond timestamps match Swift; freshness ends exactly at freshUntil and usability ends exactly at hardExpiresAt. Hard TTL receives 0–10% positive jitter; fresh TTL does not. Digest hides raw identifiers in keys but is unkeyed and must not be described as cryptographic anonymity.

| Source | Responsibility |
| --- | --- |
| `socialwireredis/namespace.go` | Scopes disposable cache keys by environment, version, and domain. Raw identifiers are SHA-256 digests; bounded safe components remain readable, with unsafe or oversized components hashed to avoid ambiguous key structure. |
| `socialwireredis/cache.go` | Maintains the Swift-compatible JSON cache envelope in epoch milliseconds. Reads distinguish fresh, stale, and miss; malformed, unknown-version, or hard-expired entries are deleted best-effort. Writes jitter hard TTL only and run through the shared circuit breaker. |
| `socialwireredis/circuit_breaker.go` | Delegates concurrent circuit generations and probe admission to gobreaker. Three consecutive failures open the circuit, five seconds permit one recovery probe, and caller cancellation is excluded from backend failure counts. |
| `socialwireredis/redis_commands.go` | Adapts go-redis commands to the repository cache interface. Missing keys become a nil-value miss, empty deletes are no-ops, and callers retain ownership of pools, TLS, retry/deadline configuration, and shutdown. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/socialwireredis/README.md).

Migration boundary: partial. Remaining: production Redis TLS/deadline configuration; ranking/lease/read-state caches and specialized clients.

## spec

Regenerate from packages/spec/endpoint-manifest.json and openapi.yaml. OpenAPIDocument returns an upstream libopenapi document; callers build its V3 model and handle model/reference errors. No route registration, HTTP serving, or authentication is introduced here.

| Source | Responsibility |
| --- | --- |
| `spec/contracts.go` | Reads the generated canonical endpoint manifest and looks up exact surface/path pairs with an uppercase method. An endpoint classification describes the contract, not runtime route availability. |
| `spec/openapi.go` | Returns libopenapi documents directly so callers use the upstream OpenAPI 3.1 model/reference implementation. Building a model is separate from creating the document and from checking service route conformance. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/spec/README.md).

Migration boundary: partial. Remaining: remaining service/route conformance checks.

## sportscore

Supply a catalog and current sports-resolver-v14 evidence. Direct associations need confidence at least 0.9 and the current version. Explicit personal mutes always win; a personal follow can override only a broader mute. Preference boosts cap at 0.35. Global reserves take precedence over the local domain/sport diversification step. Membership starts are inclusive and ends exclusive; numeric dates use the Swift 2001 epoch, not Unix seconds.

| Source | Responsibility |
| --- | --- |
| `sportscore/identity.go` | Derives entity IDs and selection record keys independently of mutable presentation. Follow and mute share the same record identity; preference fingerprints include actions and deduplicate/sort selections. |
| `sportscore/hierarchy.go` | Normalizes names with Unicode case folding and accent removal, builds active sport-parent relationships, and computes ancestor/descendant closure. Visited sets make traversal terminate even if input contains a cycle. |
| `sportscore/membership.go` | Models membership as a half-open time interval. JSON decoding accepts RFC3339 strings and legacy Swift Date numbers measured in seconds since 2001-01-01, preserving fractional seconds. |
| `sportscore/models.go` | Defines supplied catalog entities, follows/mutes, resolver evidence, and ranking candidates. The resolver-version constant gates accepted evidence; this package does not yet generate that evidence or supply a reviewed catalog. |
| `sportscore/ranker.go` | Requires current resolver evidence and finite eligible candidates. Explicit personal mutes win; a direct personal follow can override a broad mute. Materiality and capped follow boosts precede duplicate/coverage suppression, optional global slots, and bounded domain/sport diversification. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/sportscore/README.md).

Migration boundary: partial. Remaining: article resolver and entity index; reviewed catalogs and providers; provider adapters; cursors and remaining serving models.

## thinappviewcore



| Source | Responsibility |
| --- | --- |
| `thinappviewcore/projection_event.go` | Validates a stored event against its independent cursor/kind/DID metadata before decoding with the official Jetstream SDK. Numeric strings remain backward-compatible, record integers stay exact, and event-specific payload rules reject malformed commits or lifecycle events. |
| `thinappviewcore/rss_parser.go` | Translates publisher RSS, Atom, and JSON Feed bytes through gofeed into shared item fields. Published/updated timestamps fall back to the supplied clock, are rendered in UTC, and are sorted by actual instant. Network fetching and durable ingestion remain caller responsibilities. |
| `thinappviewcore/rss_thumbnail.go` | Normalizes feed/image URLs and discovers thumbnails from explicit media, article HTML, and summary HTML. The HTML tokenizer ignores comment/script text and decodes attributes. URL normalization is not a DNS, redirect, or fetch authorization check. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/thinappviewcore/README.md).

Migration boundary: partial. Remaining: transactional event application, claims and acknowledgements; repository repairs and lifecycle cleanup; RSS identities/polling and PDS backfill; stores, projections, caches and remaining models; podcast parsing, listener protocol, and store surfaces added on Development.

## wirecore

Provide the same explicit asOf instant and config when comparing results. Version, enum spelling, nil/false evidence, threshold inclusivity, reason order, key tie-breaks, and float accumulation order are compatibility contracts. Cursor integrity is not encryption; Wire cursors have no intrinsic expiry, while Circle cursors enforce viewer/snapshot/expiry. Receivers of corpus signatures must compare the exact body digest and persist nonces to prevent replay; VerifyCorpusRequest itself does neither. Canonicalize and target classification do not authorize HTTP fetching.

| Source | Responsibility |
| --- | --- |
| `wirecore/actor_hasher.go` | Produces stable secret-keyed actor pseudonyms after trim/lowercase normalization. The secret is copied on construction; rotating it intentionally changes actor identity and requires a coordinated derived-data rebuild. |
| `wirecore/candidate.go` | Defines ranking inputs, admission categories, scores, reason codes, and rejection diagnostics. Optional evidence booleans are true only when explicitly supplied; age falls back to first-seen time and is clamped for future timestamps. |
| `wirecore/canonicalizer.go` | Forms HTTPS article identities, normalizes host/default ports/path, removes fragments and known tracking parameters, and sorts semantic query pairs. Literal plus signs retain Foundation semantics; the canonical URL is SHA-256 keyed. Identity normalization is not network admission. |
| `wirecore/circle.go` | Aggregates eligible signals by participant, keeping each strongest relationship and latest timestamp. Sorted participant keys stabilize floating-point accumulation; breadth, relationship, recency/velocity, presentation, and interest components produce deterministic score/key order. |
| `wirecore/content_quality.go` | Classifies supported targets and computes explainable commercial and base adult-content evidence from URLs, text, topics, and structured indicators. These domain heuristics preserve Swift behavior and complement persisted moderation labels; they are not a general content-safety service. |
| `wirecore/corpus_trust.go` | Signs internal corpus requests with a versioned newline-delimited HMAC over service, timestamp, nonce, method, and complete target. v2 also binds a supplied body digest. Verification checks the expected service and a 60-second clock window; body comparison and replay storage belong to the receiver. |
| `wirecore/cursor.go` | Adds field/version validation around the shared signed envelope. Wire cursors bind generation/language/ordinal; Circle additionally binds a secret-derived viewer identity, snapshot, and second-precision expiry checked against the caller clock. |
| `wirecore/data_policy.go` | Centralizes bounded retention windows, graph cardinalities, clustering cadence, and candidate/first-page floors. Constants are policy inputs; host jobs and database retention must enforce them. |
| `wirecore/diversity.go` | Reranks an already scored stream using domain, publication, author, topic, and community caps. It progressively relaxes caps to meet minimum fill, completes the first page from deferred items, then appends the unselected tail without discarding ranked candidates. |
| `wirecore/edition.go` | Allocates deduplicated ranked stories to lead stories, publication panels, reason rails, and general stories in deterministic order. Trending is a separate view allowed to repeat allocated stories. Account highlights require distinct-story/speaker evidence and deterministic tie-breaks. |
| `wirecore/enum_json.go` | Rejects unrecognized JSON enum strings instead of silently accepting future target, commercial, or reason values. Database candidate loading separately maps unknown persisted values to conservative rejection classes. |
| `wirecore/ranker.go` | Validates configuration, computes reason percentiles, applies age/quality/signal admission, and combines normalized breadth, velocity, freshness, authority, and feedback signals. Penalties and deterministic rotation precede primary/backfill ordering and diversity reranking. |
| `wirecore/ranking_config.go` | Defines v10/v11 ranking versions, weights, signal thresholds, diversity caps, and longest-domain-match penalties. Time thresholds use seconds. Positive weights normalize together; negative-feedback penalty is applied separately. |
| `wirecore/regional_ranker.go` | Moves ordinary US-politics stories by three virtual slots while retaining breaking, widely discussed, and cross-community stories. Stable virtual-position and original-offset tie-breaks preserve deterministic order. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/wirecore/README.md).

Migration boundary: partial. Remaining: remaining corpus/serving models and transport bounds; full cursor/canonicalization/trust/Circle differential coverage.

## wireworkercore

This is a library, not a runnable Coordinator. Build a GenerationStore against canonical migrations, pass live authority for activation, and provide RefreshLabels before enabling cycles. Mode defaults off; shadow commits are inspectable but cannot change the active pointer. Each generation/edition commit is atomic, while separate languages/plans in a cycle are independent commits: an error later in the cycle does not roll back earlier successful generations. Publication takes a feed/language row lock, builds both editions, and checks the role fence before pointer changes. RankingScheduler is local cadence/readiness only, not distributed leadership.

| Source | Responsibility |
| --- | --- |
| `wireworkercore/candidate_queries.go` | Keeps PostgreSQL candidate projection contracts and bind ordering next to their scanners. Both candidate queries exclude expired/ineligible/moderated items and switch baseline versus external rollups together; locale discovery applies quality and signal floors before choosing at most twelve buckets. |
| `wireworkercore/candidate_store.go` | Loads canonical-schema candidate snapshots and discovers serving language buckets. The optional global metadata projection uses a read-only transaction with local planner settings; malformed topics become empty and unknown enum values fail conservatively. |
| `wireworkercore/cycle.go` | Orchestrates connectivity, optional inbox maintenance, bounded retention, mandatory label refresh, language discovery, ranking plans, and publication. Off performs connectivity only; shadow never activates; api/visible activation requires both candidate and diverse-first-page floors. |
| `wireworkercore/generation.go` | Defines the immutable publication request and store boundary needed by ranking cycles. Store implementations own transactional publication, while hosts supply authority, label refresh, inbox application, and runtime configuration. |
| `wireworkercore/generation_store.go` | Publishes generation metadata, all ranked rows, two regional edition variants, and account highlights in one PostgreSQL transaction. A feed/language lock serializes publications and the role fence is checked just before activation. Any failure rolls back all generation rows and pointer changes. |
| `wireworkercore/ranking_scheduler.go` | Serializes in-process ranking reservations with unique completion tokens. Successful cadence is measured from cycle start, failures retry after one minute and clear readiness, and stale completions cannot release a newer reservation. Distributed ownership still requires role leases. |
| `wireworkercore/retention.go` | Deletes expired inactive generations in small bounded batches, then independently cleans expired leaf tables with SKIP LOCKED. The active generation is retained even after expiry; separate statements bound transaction size and allow partial cleanup progress. |

[Package README and test inventory](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/wireworkercore/README.md).

Migration boundary: partial. Remaining: inbox application and drain; baseline label refresh transport; metadata, profile, graph and recovery jobs; Finance/Sports projectors and materializers; worker host and runtime configuration.

