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
  dead letter and enqueue DID-scoped PDS/Tap reconciliation.
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
