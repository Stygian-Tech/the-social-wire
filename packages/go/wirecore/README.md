# wirecore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/wirecore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Provide the same explicit asOf instant and config when comparing results. Version, enum spelling, nil/false evidence, threshold inclusivity, reason order, key tie-breaks, and float accumulation order are compatibility contracts. Cursor integrity is not encryption; Wire cursors have no intrinsic expiry, while Circle cursors enforce viewer/snapshot/expiry. Receivers of corpus signatures must compare the exact body digest and persist nonces to prevent replay; VerifyCorpusRequest itself does neither. Canonicalize and target classification do not authorize HTTP fetching.

## Source map

| File | Responsibility |
| --- | --- |
| [actor_hasher.go](actor_hasher.go) | Produces stable secret-keyed actor pseudonyms after trim/lowercase normalization. The secret is copied on construction; rotating it intentionally changes actor identity and requires a coordinated derived-data rebuild. |
| [candidate.go](candidate.go) | Defines ranking inputs, admission categories, scores, reason codes, and rejection diagnostics. Optional evidence booleans are true only when explicitly supplied; age falls back to first-seen time and is clamped for future timestamps. |
| [canonicalizer.go](canonicalizer.go) | Forms HTTPS article identities, normalizes host/default ports/path, removes fragments and known tracking parameters, and sorts semantic query pairs. Literal plus signs retain Foundation semantics; the canonical URL is SHA-256 keyed. Identity normalization is not network admission. |
| [circle.go](circle.go) | Aggregates eligible signals by participant, keeping each strongest relationship and latest timestamp. Sorted participant keys stabilize floating-point accumulation; breadth, relationship, recency/velocity, presentation, and interest components produce deterministic score/key order. |
| [content_quality.go](content_quality.go) | Classifies supported targets and computes explainable commercial and base adult-content evidence from URLs, text, topics, and structured indicators. These domain heuristics preserve Swift behavior and complement persisted moderation labels; they are not a general content-safety service. |
| [corpus_trust.go](corpus_trust.go) | Signs internal corpus requests with a versioned newline-delimited HMAC over service, timestamp, nonce, method, and complete target. v2 also binds a supplied body digest. Verification checks the expected service and a 60-second clock window; body comparison and replay storage belong to the receiver. |
| [cursor.go](cursor.go) | Adds field/version validation around the shared signed envelope. Wire cursors bind generation/language/ordinal; Circle additionally binds a secret-derived viewer identity, snapshot, and second-precision expiry checked against the caller clock. |
| [data_policy.go](data_policy.go) | Centralizes bounded retention windows, graph cardinalities, clustering cadence, and candidate/first-page floors. Constants are policy inputs; host jobs and database retention must enforce them. |
| [diversity.go](diversity.go) | Reranks an already scored stream using domain, publication, author, topic, and community caps. It progressively relaxes caps to meet minimum fill, completes the first page from deferred items, then appends the unselected tail without discarding ranked candidates. |
| [edition.go](edition.go) | Allocates deduplicated ranked stories to lead stories, publication panels, reason rails, and general stories in deterministic order. Trending is a separate view allowed to repeat allocated stories. Account highlights require distinct-story/speaker evidence and deterministic tie-breaks. |
| [enum_json.go](enum_json.go) | Rejects unrecognized JSON enum strings instead of silently accepting future target, commercial, or reason values. Database candidate loading separately maps unknown persisted values to conservative rejection classes. |
| [ranker.go](ranker.go) | Validates configuration, computes reason percentiles, applies age/quality/signal admission, and combines normalized breadth, velocity, freshness, authority, and feedback signals. Penalties and deterministic rotation precede primary/backfill ordering and diversity reranking. |
| [ranking_config.go](ranking_config.go) | Defines v10/v11 ranking versions, weights, signal thresholds, diversity caps, and longest-domain-match penalties. Time thresholds use seconds. Positive weights normalize together; negative-feedback penalty is applied separately. |
| [regional_ranker.go](regional_ranker.go) | Moves ordinary US-politics stories by three virtual slots while retaining breaking, widely discussed, and cross-community stories. Stable virtual-position and original-offset tie-breaks preserve deterministic order. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./wirecore`.

[content_quality_test.go](content_quality_test.go) covers:

- `TestCanonicalURLPreservesSemanticQuery`
- `TestCorpusTrustBindsCompleteTargetAndBody`
- `TestCommercialAndSafetyRules`
- `TestRegionalRankerKeepsMajorStories`

[ranker_test.go](ranker_test.go) covers:

- `TestRankingAdmissionAndBoundaries`
- `TestInvalidConfigAndNonfiniteQuality`
- `TestCircleParticipantsAndViewerBoundCursor`
- `TestActorHashNormalizationAndSecretCopy`

The [verification guide](../cmd/README.md) describes differential checks against actual Swift code and their exact limits.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- remaining corpus/serving models and transport bounds
- full cursor/canonicalization/trust/Circle differential coverage
