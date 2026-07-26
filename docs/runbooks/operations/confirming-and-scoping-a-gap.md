# Confirming and Scoping a Gap

1. Validate the detection reason: regression, disconnect window, idle connection, stale commit, backlog, overflow, or failed record.
2. Bound start/end `time_us` cursors and affected collection allowlist.
3. Run a dry-run estimate in Development.
4. Mark the gap Confirmed only when evidence shows completeness risk.
5. Prefer verified Tap resync for recovery. Jetstream Replay and DID-scoped PDS Reconciliation are diagnostics only and end in **Verification Required**; PDS current-state enumeration cannot prove historical deletes.
