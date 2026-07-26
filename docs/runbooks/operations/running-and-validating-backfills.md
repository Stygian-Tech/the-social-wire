# Running, Pausing, Resuming, and Validating Backfills

1. Run the dry-run and review its source, accuracy (`exact`, `sampled`, `estimated`, or `unavailable`), methodology, uncertainty, filters, bounds, and delete warning.
2. Optionally add an operator note. Production additionally requires typing `PRODUCTION`; the client supplies an idempotency key and expected entity version.
3. Queue the job and confirm its database lease owner, independent heartbeat, and first successful checkpoint.
4. Pause or cancel only when the action is enabled for the current version. Resume from the last successfully committed checkpoint; never checkpoint a failed record.
5. Treat Tap resync, Jetstream replay, and PDS diagnostics as different evidence classes. PDS diagnostics and Jetstream replay cannot automatically close a gap.
6. Validate exact scope, zero failures, no truncation, projection repair completion, and response freshness before a verified Tap recovery resolves the gap.

The pinned Tap build cannot currently produce that proof, so `tap_verified_resync` is intentionally
disabled. Jetstream replay and PDS diagnostics end in `verification_required`; they never substitute
for this validation or resolve the linked gap automatically.
