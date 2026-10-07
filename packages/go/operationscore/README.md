# operationscore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/operationscore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Reserve a separate control connection budget from workload/publication capacity. Operations must honor context cancellation and return after cleanup; the supervisor intentionally waits for them before release. OnEvent may run concurrently and must not block. Validate alone does not protect later writes: LockRoleLeaseFence belongs inside the transaction performing those writes.

## Source map

| File | Responsibility |
| --- | --- |
| [lease.go](lease.go) | Defines role ownership as environment, role, owner ID, and monotonically changing fencing token. Configuration reserves five seconds of lease safety margin; ownership work must carry this authority into its publication transaction. |
| [lease_supervisor.go](lease_supervisor.go) | Runs acquisition/standby and, while owned, coordinates workload, periodic renewal, and an independent expiry watchdog. Any completion cancels all owned work; joining precedes bounded release, so an old worker cannot keep publishing after reacquisition. |
| [postgres_role_lease_store.go](postgres_role_lease_store.go) | Uses PostgreSQL time and row locks to acquire, renew, validate, and release roles. A live same-owner acquisition retains its token; takeover advances it. Shared publication fences permit expiry-only renewal while excluding authority revocation. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./operationscore`.

[lease_supervisor_test.go](lease_supervisor_test.go) covers:

- `TestSupervisorJoinsBeforeRelease`
- `TestSupervisorDoesNotStartWithoutAuthority`
- `TestSupervisorWatchdogCancelsBlockedRenewal`

[postgres_role_lease_store_test.go](postgres_role_lease_store_test.go) covers:

- `TestPostgresRoleLeaseTakeover`
- `TestPostgresFenceChecksTimeAfterLock`
- `TestPostgresPublicationFenceAllowsRenewalBlocksRevocation`

PostgreSQL integration cases skip locally unless their dedicated disposable-database variables are set. See the [module guide](../README.md); a passing run with skips does not verify PostgreSQL behavior. CI supplies migrated PostgreSQL 17 and runs these cases.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- health evidence and telemetry
- recovery/control/store contracts
- remaining supported stores
- supervisor retry and observation policy parity
