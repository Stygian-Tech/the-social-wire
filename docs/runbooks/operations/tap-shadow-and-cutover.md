# Tap Shadowing and Verified Cutover

Tap is the intended verified repository-sync authority after the staged cutover. During shadowing,
Jetstream remains a separately labeled, unverified discovery and latency signal, and neither source
may claim verified recovery completeness.

The currently pinned Indigo Tap exposes repository add, remove, and info operations, but no
job-scoped resync contract that proves exact scope, complete historical deletes, and a durable
validation watermark. `tap_verified_resync` therefore remains disabled. Do not simulate resync by
removing and re-adding a repository: removal is reserved for genuine unenrollment and would weaken
the evidence boundary.

1. Confirm the Tap capability reports acknowledgement mode, persistent storage, the configured environment, and the expected collection allowlist.
2. Confirm each tracked repository has a DID, resolved PDS, account state, repository revision, last received delivery, last durably indexed mutation, projection watermark, and validation watermark.
3. Run shadow ingestion without writing a second copy into the production read model. Compare Tap deliveries with the current index by DID, collection, rkey, action, CID, account lifecycle, and projection result.
4. Exercise reconnect, redelivery, live delete, deactivation, suspension, reactivation, and PDS-move drills. Tap acknowledgements must occur only after the mutation and durable projection-repair work are committed.
5. Keep unexplained parity differences active and visible. Never turn an absent event into an observed zero or close a gap from a modeled count.
6. Require seven consecutive days with no unexplained mutation, CID, delete, or account-lifecycle discrepancies and less than five percent ingestion throughput or p95 regression.
7. Cut over one environment at a time. Keep production recovery disabled until the production telemetry-only burn-in and an explicit release approval are complete.

Before enabling verified resync, pin and validate a Tap release that supplies a safe resync endpoint
or implement an equivalently durable job-scoped validator. The drill must demonstrate exact DID,
collection, and range scope; zero failures; no truncation; complete delete semantics; and a persisted
validation watermark. Until every condition passes, the capability remains disabled with this reason.

If Tap is unavailable, preserve the last known good evidence, show the source as stale or offline, and do not silently promote Jetstream to verified completeness.
