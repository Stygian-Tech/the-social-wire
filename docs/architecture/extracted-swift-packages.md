# Extracted Swift Reference Packages

The backend runs Go. The seven former backend Swift packages now live in public,
history-preserving repositories:

| Package | Repository |
| --- | --- |
| GatewayCore | [gateway-core](https://github.com/Stygian-Tech/gateway-core) |
| ThinAppViewCore | [thin-app-view-core](https://github.com/Stygian-Tech/thin-app-view-core) |
| OperationsCore | [operations-core](https://github.com/Stygian-Tech/operations-core) |
| SocialWireRedis | [social-wire-redis](https://github.com/Stygian-Tech/social-wire-redis) |
| WireCore | [wire-core](https://github.com/Stygian-Tech/wire-core) |
| FinanceCore | [finance-core](https://github.com/Stygian-Tech/finance-core) |
| SportsCore | [sports-core](https://github.com/Stygian-Tech/sports-core) |

`ReadStateCore` remains tracked here because the Apple app imports it. The
standalone ThinAppViewCore repository includes a documented snapshot of that
dependency, preserving independent package builds without moving the active
Apple package. Each extracted repository records the source revision and
digests in `SOURCE_PROVENANCE.json`, preserves the license and package history,
and provides its own Swift CI. Database and OAuth test fixtures are bundled
where needed; four fixture-path changes are documented in provenance.

## Contract Checks

Existing Swift/Go ranking and edition parity, historical source specifications,
and retained Swift contract suites still run. Bootstrap their immutable
reference checkouts before running those checks:

```sh
python3 scripts/go/check-out-swift-contracts.py
python3 scripts/go/package-inventory.py --check
```

`packages/go/migration/extracted-swift-packages.json` pins complete Git revisions.
The checkouts occupy ignored `packages/swift/<Package>` directories so existing
oracle paths stay stable. The bootstrap verifies origin, revision, and clean
status and refuses to overwrite local work. To update a pin, review the new
package revision, preserve any existing checkout changes, replace that generated
checkout deliberately, run bootstrap, and regenerate the source inventory.

The Jetstream SDK golden fixture is now owned by the Go service under
`services/jetstream-ingest/internal/ingest/testdata`.

Extracting source packages does not reduce deployed Go runtime memory. Memory
work is tracked separately in TSW-154; extraction is TSW-153.
