# Confirming and Scoping a Gap

1. Validate the detection reason: regression, disconnect window, idle connection, stale commit, backlog, overflow, or failed record.
2. Bound start/end `time_us` cursors and affected collection allowlist.
3. Run a dry-run estimate in Development.
4. Mark the gap Confirmed only when evidence shows completeness risk.
5. Tap verified resync is retired. Prefer durable Jetstream V2 replay; DID-scoped PDS Reconciliation remains diagnostic and PDS current-state enumeration cannot prove historical deletes.
