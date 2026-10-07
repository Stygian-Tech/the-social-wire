# Migration evidence

`source-inventory.json` records every canonical shared Swift/TypeScript package and extracted service-core library, including source paths, digests, public declarations where available, and test paths. It is a source baseline, not generated Go code or implementation proof.

`status.json` separately records implemented surfaces, outstanding package/service work, and the scope of verification. A counterpart directory does not imply parity. Activation evidence is recorded separately for Development and the pending Production promotion; deploying the foundation alone does not complete a runtime handoff.

Run `python3 scripts/go/package-inventory.py --check` from the repository root to detect canonical source drift. When canonical contracts change, review their implications, update the Go implementation and status where appropriate, then regenerate with `python3 scripts/go/package-inventory.py`. Do not refresh digests merely to silence an unexplained failure.

Generated schema data comes from a different tool, `scripts/go/generate-contracts.py`. The inventory and bundles are reviewed independently. Neither artifact records a live deployment or promises the pending stores/auth/resolvers are implemented.

This Production candidate inventories the retained Swift rollback sources. It omits Development retirement provenance because those sources remain present on this branch.
