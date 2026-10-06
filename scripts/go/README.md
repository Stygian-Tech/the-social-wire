# Go migration tooling

Run these tools from the repository root. They keep source contracts and migration evidence local; none deploys a service or modifies a hosted database.

| Tool | Responsibility |
| --- | --- |
| `generate-contracts.py` | Reads canonical Lexicon JSON, rejects duplicate IDs, embeds the endpoint manifest/OpenAPI, and computes the OpenAPI SHA-256 digest. `--check` fails on byte drift without writing. |
| `package-inventory.py` | Records canonical Swift/TypeScript package and extracted service-core sources, digests, declarations, and tests. `--check` detects source-baseline drift; refreshing it does not prove parity. |
| `verify-ranking-parity.sh` | Compiles actual Wire Swift source and the Go stdin/stdout bridge into a temporary directory, then invokes the seeded comparison driver. |
| `verify-ranking-parity.py` | Exercises 30 empty, admission/age/quality/threshold/diversity and seeded snapshots. Requires identical order, reasons and diagnostics; score absolute tolerance is `1e-12`. |
| `ranking-oracle.swift` | Swift JSON bridge with explicit `asOf` and optional config; delegates to the actual ranker. |
| `verify-edition-parity.sh` | Compiles actual edition assembler/models and the Go edition bridge; cleans temporary artifacts on exit. |
| `verify-edition-parity.py` | Compares complete decoded JSON for 35 fixed-clock seeded editions, including duplicate stories, sections, bounded fields and account evidence. |
| `edition-oracle.swift` | Converts supplied account evidence to Swift candidates and emits a complete fixture edition with ISO8601 dates. |
| `verify-domain-ranking-parity.sh` | Compiles actual Finance/Sports rankers and models, extracts current resolver constants/normalization, and supplies only the hierarchy IDs required by the oracle. |
| `verify-domain-ranking-parity.py` | Compares ordered Finance/Sports IDs across 45 seeded preference, materiality, mute, duplicate, global-slot and diversity snapshots. |
| `domain-ranking-oracle.swift` | Converts preferences to sets and emits ordered domain IDs; it does not perform article analysis. |

## Regeneration

Review canonical contract changes before regenerating:

```sh
python3 scripts/go/generate-contracts.py
python3 scripts/go/package-inventory.py
python3 scripts/go/generate-contracts.py --check
python3 scripts/go/package-inventory.py --check
```

Edit the generator for generated comments; do not hand-edit `contracts_generated.go`. Inventory targets include pending service libraries, so a recorded path does not necessarily exist or implement the original surface yet. `packages/go/migration/status.json` is the separate completion record.

## Differential checks

```sh
bash scripts/go/verify-ranking-parity.sh
bash scripts/go/verify-edition-parity.sh
bash scripts/go/verify-domain-ranking-parity.sh
```

Go 1.26, Swift 6.2.4, Python 3, and Bash are required. Fixed clocks/seeds preserve reproduction; drivers run actual Swift implementations rather than a translated Python oracle. Coverage is bounded to these fixtures and stated outputs. Circle, full cursor/trust/canonicalization conformance, article resolvers, catalogs, provider adapters, and full worker runtime parity remain outstanding.

Package unit/integration checks and disposable PostgreSQL setup are in [packages/go/README.md](../../packages/go/README.md). Keep authored variables descriptive; `t *testing.T`, `_` discarded bindings, and `T` generic type parameters are standard Go conventions. Avoid single-letter workload, authority, decoder, candidate, or error names.
