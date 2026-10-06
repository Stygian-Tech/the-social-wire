# wireworkercore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/wireworkercore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

This is a library, not a runnable Coordinator. Build a GenerationStore against canonical migrations, pass live authority for activation, and provide RefreshLabels before enabling cycles. Mode defaults off; shadow commits are inspectable but cannot change the active pointer. Each generation/edition commit is atomic, while separate languages/plans in a cycle are independent commits: an error later in the cycle does not roll back earlier successful generations. Publication takes a feed/language row lock, builds both editions, and checks the role fence before pointer changes. RankingScheduler is local cadence/readiness only, not distributed leadership.

## Source map

| File | Responsibility |
| --- | --- |
| [candidate_queries.go](candidate_queries.go) | Keeps PostgreSQL candidate projection contracts and bind ordering next to their scanners. Both candidate queries exclude expired/ineligible/moderated items and switch baseline versus external rollups together; locale discovery applies quality and signal floors before choosing at most twelve buckets. |
| [candidate_store.go](candidate_store.go) | Loads canonical-schema candidate snapshots and discovers serving language buckets. The optional global metadata projection uses a read-only transaction with local planner settings; malformed topics become empty and unknown enum values fail conservatively. |
| [cycle.go](cycle.go) | Orchestrates connectivity, optional inbox maintenance, bounded retention, mandatory label refresh, language discovery, ranking plans, and publication. Off performs connectivity only; shadow never activates; api/visible activation requires both candidate and diverse-first-page floors. |
| [generation.go](generation.go) | Defines the immutable publication request and store boundary needed by ranking cycles. Store implementations own transactional publication, while hosts supply authority, label refresh, inbox application, and runtime configuration. |
| [generation_store.go](generation_store.go) | Publishes generation metadata, all ranked rows, two regional edition variants, and account highlights in one PostgreSQL transaction. A feed/language lock serializes publications and the role fence is checked just before activation. Any failure rolls back all generation rows and pointer changes. |
| [ranking_scheduler.go](ranking_scheduler.go) | Serializes in-process ranking reservations with unique completion tokens. Successful cadence is measured from cycle start, failures retry after one minute and clear readiness, and stale completions cannot release a newer reservation. Distributed ownership still requires role leases. |
| [retention.go](retention.go) | Deletes expired inactive generations in small bounded batches, then independently cleans expired leaf tables with SKIP LOCKED. The active generation is retained even after expiry; separate statements bound transaction size and allow partial cleanup progress. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./wireworkercore`.

[cycle_test.go](cycle_test.go) covers:

- `TestCycleRequiresLabelsBeforeBuilding`
- `TestCycleActivationFloorAndExternalShadow`
- `TestCycleShadowCannotActivate`
- `TestRankingSchedulerCadenceAndReadiness`

[generation_store_test.go](generation_store_test.go) covers:

- `TestGenerationCandidateProjectionMatchesOriginal`
- `TestGenerationPublicationAndStaleFenceRollback`

PostgreSQL integration cases skip locally unless their dedicated disposable-database variables are set. See the [module guide](../README.md); a passing run with skips does not verify PostgreSQL behavior. CI supplies migrated PostgreSQL 17 and runs these cases.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- inbox application and drain
- baseline label refresh transport
- metadata, profile, graph and recovery jobs
- Finance/Sports projectors and materializers
- worker host and runtime configuration
