# financecore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/financecore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Supply eligible ArticleAnalysis from the canonical resolver. Ranking personalizes an existing base score and does not mutate it. Instrument boost is 0.25, sector boost 0.10, total capped at 0.35; materiality is multiplicative. Six-hour coverage suppression requires a normalized headline of at least twenty characters and a publication date. Global reservation uses every fifth slot when an eligible major-global candidate remains.

## Source map

| File | Responsibility |
| --- | --- |
| [identity.go](identity.go) | Derives stable instrument and PDS selection identifiers from provider-native identity, then fingerprints sorted, deduplicated preferences. Display names and input order cannot change these keys. |
| [models.go](models.go) | Defines the evidence and candidate shapes consumed by Finance ranking. These are analysis inputs, not an article resolver or a reviewed instrument catalog. |
| [ranker.go](ranker.go) | Filters ineligible/nonfinite candidates, applies materiality and capped preference boosts, breaks ties by item ID, and suppresses duplicate URLs and six-hour headline/entity coverage. Optional global slots are filled from remaining candidates by base score. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./financecore`.

[ranker_test.go](ranker_test.go) covers:

- `TestFinanceReservesGlobalSlotAfterPersonalization`
- `TestFinanceCoverageSuppressionDoesNotReserveDroppedIdentity`
- `TestFinanceIdentityExcludesMutablePresentation`

The [verification guide](../cmd/README.md) describes differential checks against actual Swift code and their exact limits.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- article resolver and topic evidence
- reviewed catalogs and named feeds
- provider adapters and rights constraints
- cursors and remaining serving models
