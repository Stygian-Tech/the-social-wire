# Differential oracle commands

These commands consume one JSON snapshot on stdin, emit JSON on stdout, and exit nonzero on decoding, ranking, or encoding errors. They never open database connections, acquire authority, publish generations, or serve HTTP. The shell drivers build them alongside the actual Swift implementation and compare deterministic fixture snapshots.

| Command | Input | Output and comparison |
| --- | --- | --- |
| `ranking-parity` | `candidates`, explicit `asOf`, optional ranking `config` | Complete Wire result; Python compares keys/order, reasons and diagnostics exactly, scores with absolute tolerance `1e-12`. |
| `edition-parity` | `items`, `accounts`, explicit `asOf` | Complete edition with fixed fixture generation/und language/ranked source; full decoded JSON equality. |
| `domain-ranking-parity` | `finance`, `sports`, instrument/sector/follow/mute IDs, entities, reserve flag | Ordered Finance/Sports IDs only; no score, article-resolver, provider, or catalog parity claim. |

Run from the repository root:

```sh
bash scripts/go/verify-ranking-parity.sh
bash scripts/go/verify-edition-parity.sh
bash scripts/go/verify-domain-ranking-parity.sh
```

Drivers use disposable build directories and clean them on exit. They require Go 1.26 and Swift 6.2.4. Fixtures use fixed clocks and random seeds so regressions are reproducible. The domain driver extracts resolver version/normalization helpers and supplies only the reviewed hierarchy identities needed by the ranker; it is not a substitute article resolver.

See [scripts/go/README.md](../../../scripts/go/README.md) for generator, inventory, and fixture responsibilities, and the [module guide](../README.md) for integration checks.
