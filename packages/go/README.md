# Repository-local Go packages

One shared module, pinned to the ingestion service's Go toolchain. Services import
`github.com/stygian-tech/the-social-wire/packages/go/<package>` and resolve it with
`replace github.com/stygian-tech/the-social-wire/packages/go => ../../packages/go`.
Run builds with `GOWORK=off`; no published copy of this module is required.

The migration is **in progress**. Every package in the source inventory has a Go
counterpart, but counterparts are not yet complete. No projection or coordinator
service has been replaced by this change. See [migration/status.json](migration/status.json)
for implemented surfaces and outstanding parity work. Package directories alone
are not completion evidence.

```sh
python3 scripts/go/generate-contracts.py --check
python3 scripts/go/package-inventory.py --check
GOWORK=off go -C packages/go vet ./...
GOWORK=off go -C packages/go test -race ./...
bash scripts/go/verify-ranking-parity.sh
bash scripts/go/verify-edition-parity.sh
bash scripts/go/verify-domain-ranking-parity.sh
```

Run those commands from the repository root. Differential checks require Swift
6.2.4 and compile the actual Swift algorithms. Wire ranking requires identical
admission, ordering, reasons and diagnostics; scores permit absolute error up to
`1e-12`. Edition assembly compares complete JSON. Finance/Sports comparisons
check ranked IDs; they do not verify article resolvers or catalogs.

PostgreSQL tests require `SOCIALWIRE_GO_TEST_DATABASE_URL` pointing to a disposable
PostgreSQL 17 database. They install the existing role-lease migrations there.
Generation tests additionally require `SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL`
pointing to a disposable database with all canonical migrations applied through
`scripts/apply-database-migrations.sh`. Tests never use `DATABASE_URL`. The publication fence must run inside the same
transaction as the protected writes. Lease control connections must be reserved
separately from workload capacity. A supervisor joins cancelled work before
releasing ownership.

Lexicon and OpenAPI data is generated from existing canonical repository sources:

```sh
python3 scripts/go/generate-contracts.py
python3 scripts/go/package-inventory.py
```

Review contract changes before refreshing the source inventory. The registry
exposes schema definitions; generated typed models and full Lexicon validation
are still outstanding. Gateway payload inspection is not authentication: access
token and DPoP verification must not be switched to this package until the
issuer-binding and trust adapters have conformance coverage.

Standard infrastructure uses upstream libraries directly: gofeed for feeds,
`x/net/html` for thumbnails, go-redis for Redis commands, gobreaker for circuit
state, go-ipld-prime for DAG-CBOR, go-jose for compact JWS inspection, the official
Jetstream SDK for provider events, and libopenapi for OpenAPI 3.1 models. These
are pinned dependencies of this repository-local module; domain contracts stay
here. Redis callers configure and own their go-redis clients, including TLS,
deadlines, and shutdown.

The library adoption intentionally fixes fractional feed dates, chronological
sorting across offsets, and thumbnail matches inside comments or scripts. The
breaker uses a fixed five-second cooldown, three consecutive failures, and one
half-open probe; old request completions cannot close a newer open circuit.
Jetstream record values must be objects. JOSE inspection rejects unsigned or
malformed envelopes but still does not verify signatures or authenticate users.
Canonical receipt/intent hashes remain identical to the shared fixtures.
