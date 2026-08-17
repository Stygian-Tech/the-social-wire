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
   through that boundary is applied, reconciled, or explicitly terminalized by the current scope
   policy.

## Projection failures

- Charybdis leases at most one actionable event per DID so repository order is preserved while
  unrelated DIDs run concurrently.
- Transient failures return to the inbox with bounded backoff. Ten failed attempts move an event to
  dead letter and enqueue DID-scoped PDS reconciliation.
- A dead letter, sync marker, or repository revision mismatch is a projection-correctness incident,
  not proof that the transport skipped a numeric sequence.
- Do not manually edit the staged or applied watermark. Recovery is inclusive and idempotent.

## Out-of-scope backlog

Standard Site content is actionable only while its repository DID is a current publication author.
Skyreader and graph-subscription commits are actionable only for a current AppView viewer.
Read-state records remain outside V2 intake because authenticated AppView mutations own that
projection. The ingester checks those roles in the same transaction that stages a batch; Charybdis uses
the same policy when claiming older rows.

If a historical generation contains globally staged commits, let Charybdis mark the currently
out-of-scope subset `filtered_scope` in bounded, row-locked batches. Each decision records the stable
scope-policy version and timestamp. This is a terminal outcome, but it is deliberately distinct from
both projection (`applied`) and PDS repair (`reconciled`). The normal terminal-prefix query advances
the applied watermark after each batch. Never bulk-delete the rows, rewrite their status manually,
or jump the checkpoint; a new or reactivated scope must instead complete PDS backfill.

## Rollout and rollback

- `v1_authoritative`: legacy V1 projects data; the V2 inbox is not drained.
- `v2_shadow`: legacy V1 projects data while the V2 service stages durability evidence.
- `v2_authoritative`: Charybdis drains the V2 inbox and does not run the legacy subscriber.

Development must complete the documented shadow comparison, fault drills, and seven-day soak before
Production is considered. Rollback to V1 authority does not delete V2 checkpoints, inbox rows, raw
gap signals, or consolidated incidents.

### Changing the scope policy generation

The role-aware scope policy is part of the ingester filter fingerprint. Never let a new generation
start implicitly at the live tip.

1. Scale the Jetstream V2 Ingest service to zero, then verify its old fenced lease is released or
   expired. A failed Railway replacement can leave the previous healthy deployment running, so a
   failed new deployment is not evidence that intake stopped.
2. Record the old generation's exact `last_staged_seq` after intake stops and keep Charybdis
   configured to that old generation. Also remove any `JETSTREAM_COLLECTIONS` override that contains
   collections outside the new policy.
3. Deploy the migration and scope-aware Charybdis while the ingester remains scaled to zero.
4. Let Charybdis terminalize the old generation's out-of-scope rows and project or reconcile every
   remaining desired row. Require its terminal prefix to reach the recorded staged seam with zero
   actionable rows, unresolved dead letters, or recovery incidents.
5. Set `JETSTREAM_SOURCE_GENERATION` on both Charybdis and Jetstream V2 Ingest to the new generation.
   Set `JETSTREAM_BOOTSTRAP_AFTER_SEQ` on the ingester to one less than the recorded old-generation
   seam, creating an inclusive duplicate overlap. A new generation without that explicit cursor
   fails closed.
6. Scale the ingester back to one replica, require a fresh fenced lease and live checkpoint, then
   verify Charybdis on the same generation. Run exact active-scope PDS reconciliation before
   declaring the seam complete.

After a generation handoff, Charybdis may automatically resolve an `open` or `recovering`
`fatal_stream` incident from the retired generation. The
`retired-generation-terminal-v1` policy is deliberately fail-closed and applies only when all of
these facts are true in one durable store evaluation:

- the configured successor has a `live` checkpoint and a current, unreleased fenced intake lease;
- the successor and retired checkpoints use the same source host, stream NSID, and cursor kind;
- the successor's `replay_after_seq` is below the retired `last_staged_seq`, and the successor has
  staged through at least that retired seam, proving the required inclusive overlap was observed;
- the retired checkpoint is `live`, has no active intake lease, and its terminal-prefix
  `last_applied_seq` has reached its recorded `last_staged_seq`;
- the retired generation has no row beyond the recorded seam, no actionable inbox row, no
  unreconciled dead letter, and no pending, leased, or failed reconciliation request; and
- the incident's cursor range is absent or is fully covered by the retired terminal prefix.

The resolver never changes current-generation incidents, `verification_required` incidents, other
incident categories, or a candidate that lacks any of this evidence. A successful transition
records both generation IDs, both sides of the inclusive seam, the successor checkpoint and lease
observations, and the policy version in `verification_evidence`; it also records the recovered
cursor and resolution time. Re-running the resolver is idempotent. Do not manually edit an incident
that remains active: diagnose the missing invariant instead.

Automated retired-generation incident resolution proves only that the recorded transport seam and
retired inbox are terminal. It does not replace exact active-scope PDS reconciliation, which remains
required to validate the current records for every enrolled author and viewer repository before the
generation handoff or a Production promotion is accepted.

Repeat this sequence independently in each environment. A Development cursor is never valid for
Production.

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
