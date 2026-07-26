# Jetstream Disconnect and Reconnect

Jetstream is an explicitly unverified supplemental source during the Tap migration. Its cursor can identify a transport interval, but cannot certify repository completeness or automatically resolve a gap.

1. Confirm the active Jetstream, both endpoints' connectivity, disconnect time, and bounded reason in Operations → Ingestion.
2. Compare the last received and committed `time_us` cursors. Never resume from `commit.rev`.
3. The worker fails over to the standby endpoint after a connection failure. It stays on the healthy endpoint until that endpoint fails; it never consumes both streams concurrently.
4. If automatic recovery is not progressing, choose **Reconnect Jetstream** and confirm the production environment when required. The current connection state is recorded automatically as the audit context.
5. Follow the command from queued to running to completed. Completion requires a reopened stream, durable cursor advancement, and a post-connect gap assessment; opening the socket alone is not completion.
6. Verify committed cursor advancement and a stable receive-to-commit backlog for five minutes.
7. If received is ahead of committed or the pump overflowed, investigate the generated suspected gap before running a dry-run backfill.

Do not manually advance the committed cursor. Duplicate overlap is safe; skipping is not. A successful Jetstream replay ends in **Verification Required** until Tap or an operator supplies verified recovery evidence.
