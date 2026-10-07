# Migration evidence

`source-inventory.json` records every canonical shared Swift/TypeScript package and extracted service-core library, including source paths, digests, public declarations where available, and test paths. It is a source baseline, not generated Go code or implementation proof.

`status.json` separately records implemented surfaces, outstanding package/service work, and the scope of verification. A counterpart directory does not imply parity. `serviceActivation: not_started` describes the Go projection/coordinator cutover; deploying the foundation does not complete that activation.

Run `python3 scripts/go/package-inventory.py --check` from the repository root to detect canonical source drift. When canonical contracts change, review their implications, update the Go implementation and status where appropriate, then regenerate with `python3 scripts/go/package-inventory.py`. Do not refresh digests merely to silence an unexplained failure.

Generated schema data comes from a different tool, `scripts/go/generate-contracts.py`. The inventory and bundles are reviewed independently. Neither artifact records a live deployment or promises the pending stores/auth/resolvers are implemented.

`retired-worker-sources.json` preserves the source revision, paths and digests of retired Swift worker code. The generated inventory includes this provenance separately from active shared packages; historical source evidence does not claim live runtime acceptance.
