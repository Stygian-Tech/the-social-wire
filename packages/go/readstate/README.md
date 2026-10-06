# readstate

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/readstate`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Use aliases when callers need the implemented shared protocol without a second copy of its model definitions. Storage, repository traversal, sync, outbox, compaction, and garbage collection are still absent; do not infer completeness from this facade.

## Source map

| File | Responsibility |
| --- | --- |
| [protocol.go](protocol.go) | Re-exports the implemented ReadStateCore protocol surfaces using aliases, preserving type identity across imports. This facade provides no repository, outbox, persistence, sync, or garbage collector. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./readstate`.

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- repository/outbox/GC and persistence contracts
- remaining TypeScript protocol conformance cases
