# sportscore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/sportscore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Supply a catalog and current sports-resolver-v14 evidence. Direct associations need confidence at least 0.9 and the current version. Explicit personal mutes always win; a personal follow can override only a broader mute. Preference boosts cap at 0.35. Global reserves take precedence over the local domain/sport diversification step. Membership starts are inclusive and ends exclusive; numeric dates use the Swift 2001 epoch, not Unix seconds.

## Source map

| File | Responsibility |
| --- | --- |
| [identity.go](identity.go) | Derives entity IDs and selection record keys independently of mutable presentation. Follow and mute share the same record identity; preference fingerprints include actions and deduplicate/sort selections. |
| [hierarchy.go](hierarchy.go) | Normalizes names with Unicode case folding and accent removal, builds active sport-parent relationships, and computes ancestor/descendant closure. Visited sets make traversal terminate even if input contains a cycle. |
| [membership.go](membership.go) | Models membership as a half-open time interval. JSON decoding accepts RFC3339 strings and legacy Swift Date numbers measured in seconds since 2001-01-01, preserving fractional seconds. |
| [models.go](models.go) | Defines supplied catalog entities, follows/mutes, resolver evidence, and ranking candidates. The resolver-version constant gates accepted evidence; this package does not yet generate that evidence or supply a reviewed catalog. |
| [ranker.go](ranker.go) | Requires current resolver evidence and finite eligible candidates. Explicit personal mutes win; a direct personal follow can override a broad mute. Materiality and capped follow boosts precede duplicate/coverage suppression, optional global slots, and bounded domain/sport diversification. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./sportscore`.

[membership_test.go](membership_test.go) covers:

- `TestMembershipAcceptsBothPersistedDateFormats`
- `TestMembershipRejectsMissingOrNullStart`

[ranker_test.go](ranker_test.go) covers:

- `TestPersonalFollowOverridesBroadMuteOnly`
- `TestSportsRejectsStaleResolverEvidence`
- `TestSportsHierarchyCycleTerminates`
- `TestSportsPreferenceAndSelectionIdentity`

The [verification guide](../cmd/README.md) describes differential checks against actual Swift code and their exact limits.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- article resolver and entity index
- reviewed catalogs and providers
- provider adapters
- cursors and remaining serving models
