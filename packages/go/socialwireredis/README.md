# socialwireredis

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/socialwireredis`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Use NewCacheClient with RedisCommands backed by a caller-owned go-redis client. Configure TLS, command deadlines, retries, pool sizing, and Close at the service boundary. Treat ErrCircuitOpen/transport errors as optional-cache failure and choose durable fallback explicitly. Millisecond timestamps match Swift; freshness ends exactly at freshUntil and usability ends exactly at hardExpiresAt. Hard TTL receives 0–10% positive jitter; fresh TTL does not. Digest hides raw identifiers in keys but is unkeyed and must not be described as cryptographic anonymity.

## Source map

| File | Responsibility |
| --- | --- |
| [namespace.go](namespace.go) | Scopes disposable cache keys by environment, version, and domain. Raw identifiers are SHA-256 digests; bounded safe components remain readable, with unsafe or oversized components hashed to avoid ambiguous key structure. |
| [cache.go](cache.go) | Maintains the Swift-compatible JSON cache envelope in epoch milliseconds. Reads distinguish fresh, stale, and miss; malformed, unknown-version, or hard-expired entries are deleted best-effort. Writes jitter hard TTL only and run through the shared circuit breaker. |
| [circuit_breaker.go](circuit_breaker.go) | Delegates concurrent circuit generations and probe admission to gobreaker. Three consecutive failures open the circuit, five seconds permit one recovery probe, and caller cancellation is excluded from backend failure counts. |
| [redis_commands.go](redis_commands.go) | Adapts go-redis commands to the repository cache interface. Missing keys become a nil-value miss, empty deletes are no-ops, and callers retain ownership of pools, TLS, retry/deadline configuration, and shutdown. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./socialwireredis`.

[cache_test.go](cache_test.go) covers:

- `TestSwiftCacheEnvelopeBoundaries`
- `TestMalformedCacheIsMiss`
- `TestCacheStoreTTLAndRoundTrip`
- `TestCircuitBreakerIgnoresOlderSuccess`
- `TestCircuitBreakerOneConcurrentRecoveryProbe`
- `TestCacheErrorsOpenCircuit`
- `TestNamespaceHidesIdentifiers`

[redis_commands_test.go](redis_commands_test.go) covers:

- `TestRedisTransportCacheRoundTripAndExpiry`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- production Redis TLS/deadline configuration
- ranking/lease/read-state caches and specialized clients
