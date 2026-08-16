# Jetstream V2 Durable Replay

Jetstream V2 intake is split between the private Go ingester and Charybdis. The ingester owns the
host-scoped V2 cursor and atomically stages events in Postgres. Charybdis owns projection work and
never advances the intake cursor. Redis is not part of either durability boundary.

## Normal recovery

1. Check the source generation, host, filter fingerprint, and cursor kind. A cursor is valid only for
   that exact identity; never reuse a US-West sequence on US-East.
2. Compare the last staged sequence with the last fully applied sequence, inbox depth, and oldest
   actionable row. Sequence-number subtraction is not an event-loss count.
3. On a socket interruption or `ConsumerTooSlow`, allow the ingester to reconnect from the inclusive
   staged sequence. Duplicate inserts are expected and deduplicated by the inbox primary key.
4. On `CursorTooOld`, confirm the incident enters archive replay. The ingester plans a sealed
   snapshot, resumes ETag/range downloads, stages the archive, and then cuts back to live.
5. For `429`, verify the server's `Retry-After` is honored. A paused replay retains its checkpoint and
   automatically resumes when the rolling 24-hour byte budget permits. Exhausting the per-incident
   limit is a hard stop: inspect the incident and deliberately raise the configured limit or begin a
   separately audited recovery; never reset the counter on a timer.
6. Resolve a transport incident only after replay reaches the sealed/live seam and every staged row
   through that boundary is applied or reconciled.

## Projection failures

- Charybdis leases at most one actionable event per DID so repository order is preserved while
  unrelated DIDs run concurrently.
- Transient failures return to the inbox with bounded backoff. Ten failed attempts move an event to
  dead letter and enqueue DID-scoped PDS reconciliation.
- A dead letter, sync marker, or repository revision mismatch is a projection-correctness incident,
  not proof that the transport skipped a numeric sequence.
- Do not manually edit the staged or applied watermark. Recovery is inclusive and idempotent.

## Rollout and rollback

- `v1_authoritative`: legacy V1 projects data; the V2 inbox is not drained.
- `v2_shadow`: legacy V1 projects data while the V2 service stages durability evidence.
- `v2_authoritative`: Charybdis drains the V2 inbox and does not run the legacy subscriber.

Development must complete the documented shadow comparison, fault drills, and seven-day soak before
Production is considered. Rollback to V1 authority does not delete V2 checkpoints, inbox rows, raw
gap signals, or consolidated incidents.

### Changing authority on Railway

Changing `THIN_APPVIEW_JETSTREAM_MODE` may create a `SKIPPED` deployment when the Git revision is
unchanged. A skipped deployment does not prove that a running Charybdis process loaded the new mode.
After setting the variable:

1. Verify that Railway creates a non-skipped Charybdis deployment from the intended revision. If it
   suppresses the variable-only deployment, run a fresh-source redeploy for Charybdis.
2. Require the new process log to report the intended `jetstream_mode`.
3. Require the Charybdis deployment to reach `SUCCESS`; its Railway health check calls `/startupz`,
   which checks database connectivity while allowing the durable inbox to catch up. Then require
   `/readyz` to succeed before treating Charybdis as ready; it checks the database, fresh worker
   heartbeat, authoritative transport, and authoritative projection freshness/completeness.
4. Confirm the active fenced ingester lease heartbeat remains fresh, the matching source
   generation's actionable inbox stays inside the freshness budget, and there are no dead letters
   or unresolved ingestion incidents. Checkpoint `updated_at` is not an intake heartbeat because
   projection and reconciliation work can also advance it.
5. Check the public Gateway `/readyz` separately. It aggregates Gateway database, App View, and
   Charybdis readiness, so a failure there is not by itself proof that Charybdis failed.

For rollback, restore `THIN_APPVIEW_JETSTREAM_MODE=v2_shadow` and apply the same non-skipped
deployment checks. Preserve all V2 state for diagnosis and a later retry.

### Production rollout record

Production was explicitly switched to `v2_authoritative` on 2026-08-16 by operator direction before
the recommended seven-day Development soak completed. Deployment
`afc03fa0-2ac5-4d1e-96ce-f434cc02a23e` loaded the mode on revision
`e07324991e37492eb67c97679503a778684419aa` and passed the then-configured Charybdis Railway
`/readyz` check. Treat the shortened soak as accepted rollout risk, not as evidence that the
documented soak occurred.
