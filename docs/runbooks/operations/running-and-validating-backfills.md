# Running, Pausing, Resuming, and Validating Backfills

1. Run the dry-run and review its source, accuracy (`exact`, `sampled`, `estimated`, or `unavailable`), methodology, uncertainty, filters, bounds, and delete warning.
2. Optionally add an operator note. Production additionally requires typing `PRODUCTION`; the client supplies an idempotency key and expected entity version.
3. Queue the job and confirm its database lease owner, independent heartbeat, and first successful checkpoint.
4. Pause or cancel only when the action is enabled for the current version. Resume from the last successfully committed checkpoint; never checkpoint a failed record.
5. Treat retired Tap evidence, Jetstream replay, and PDS diagnostics as different evidence classes. PDS diagnostics cannot automatically close a gap.
6. Validate exact scope, zero failures, no truncation, projection repair completion, and response freshness before durable V2 recovery resolves the gap.

Tap is no longer deployed, so `tap_verified_resync` remains disabled as a
historical compatibility mode. PDS diagnostics still end in
`verification_required`; they never substitute for exact-scope validation or
resolve the linked gap automatically.
