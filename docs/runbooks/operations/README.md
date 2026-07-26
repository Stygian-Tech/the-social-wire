# Operations Runbooks

These are the canonical operator procedures rendered by `apps/operations`. Use the Development environment first and preserve request, trace, command, and idempotency IDs in incident notes. Operator notes are optional; the control plane always records actor, environment, before/after state, and outcome.

1. [Tap Shadowing and Verified Cutover](./tap-shadow-and-cutover.md)
2. [Jetstream Disconnect and Reconnect](./jetstream-disconnect-reconnect.md)
3. [Live Process With Stalled Ingestion](./live-process-stalled-ingestion.md)
4. [Finding the Last Safe Checkpoint](./finding-last-safe-checkpoint.md)
5. [Confirming and Scoping a Gap](./confirming-and-scoping-a-gap.md)
6. [Running and Validating Backfills](./running-and-validating-backfills.md)
7. [AppView Latency and Error Investigation](./appview-latency-errors.md)
8. [Client Cache Versus AppView Staleness](./client-cache-versus-appview-staleness.md)
9. [Disabling or Rolling Back Telemetry](./disabling-rollback-telemetry.md)
