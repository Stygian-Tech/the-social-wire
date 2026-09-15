# Development Wire Replay Budget Recovery

Track this incident in TSW-126 under TSW-92. A budget pause is incomplete intake,
not proof of a database capacity problem or an upstream outage. Preserve the
existing source generation, source/filter identity, checkpoints, recovery anchors,
incidents, and protected inbox records.

## Retained Evidence

The bounded read-only snapshot at 2026-09-15 01:21 UTC found:

- Generation `wire-global-v4-dev-live-20260830`, source
  `jetstream.us-west.bsky.network`, cursor kind `jetstream_v2_seq`.
- Last staged sequence 24,941,814,727 at September 7 17:13:39 UTC.
  Replay lower seam 24,941,037,520; last observed sealed tip 25,544,509,826.
  The tip is historical provider evidence, not a current live target.
- State `paused_budget`; incident usage 5,368,919,351 bytes, exceeding the
  unchanged default 5 GiB limit by 210,231 bytes. Downloads already in flight
  can cross the limit; the transport accounts for those bytes.
- The open budget incident first appeared September 7 17:13:40 UTC. The
  no-progress incident remains open. No linked legacy gap rows were returned;
  that does not establish continuous coverage or resolve either incident.
- Four retained recent usage buckets total 6,144 bytes. No staged progress has
  occurred since September 7. These small subsequent attempts are consistent
  with restart-time requests rejected after opening the archive response.
- Original download usage buckets have expired under existing retention. The
  current evidence cannot divide the original 5 GiB into useful bytes and
  repeated downloads. Incident range-resume evidence (2) exceeds the checkpoint
  value (0); restarting paused recoveries previously failed to seed that evidence.
- The Development Wire admission counter is zero and no active local ranking
  generations were returned. Development viewers use the separately configured
  Production Corpus Edge: local intake readiness is not their serving-readiness
  or freshness measurement. Inspect the served generation timestamp separately.

A separate unauthenticated English feed sample at 01:27 UTC returned HTTP 200
from both Development and Production with the same ranked generation, generated
at 01:23:36 UTC (about four minutes old). Both retained `degraded=true`; this is
serving continuity evidence, not complete recovery or authenticated acceptance.

The focused code fix rejects archive requests before opening a connection when
incident capacity is exhausted and retains checkpoint transport evidence across
paused/failed restarts. It does not resume this incident or reconstruct lost
historical evidence. `/startupz` stays database-based; `/readyz` remains 503 for a
paused lane and for its aggregate controller.

## Provider Plan Evidence

One metadata-only `planSnapshot` request at 01:32 UTC returned HTTP 200 in
640 ms (40,755 response bytes). It requested the existing inclusive resume
`afterSeq=24941814726` and capped `beforeSeq=25544509826` at the historical sealed
target. The provider planned through that target in one page: 260 matched
segments, 134,742 matched blocks, 486 plan entries. The earliest segment began
at 24,941,794,474, before the requested seam. No archive objects were downloaded.

This supports availability of a plan for the historical range; it does not prove
successful byte download, event continuity, or coverage through today's live tip.
The plan schema contains no compressed-byte sizes. A safe allowance still needs
provider size metadata (or a separately reviewed bounded HEAD inspection), not
multiplication of sparse sequence counts. Do not automatically page to a newer
live target or turn this successful metadata response into a recovery claim.

## Recovery Review Gate

Do not raise the limit, reset usage, change the generation/bootstrap cursor, mark
an incident resolved, or delete/requeue records simply to make health green.
A normal restart cannot recover this incident under its existing byte limit.

Before proposing any additional download allowance:

1. Preserve an exact checkpoint/source-identity and open-incident snapshot.
   Obtain a separately approved, metadata-only provider plan for the unchanged
   resume cursor (the client deliberately replays the last staged sequence).
   Bound that inspection to one request, 10 seconds, and 1 MiB; no segment/block
   downloads or automatic retries. A truncated/unavailable plan is inconclusive.
2. Verify the provider still covers the retained seam and identify the complete
   sealed target, archive sizes, filters and Range/ETag behavior. Do not infer
   bytes from sequence distance: these sequences are sparse. If the seam has
   expired, escalate the coverage decision rather than selecting a newer cursor.
3. Present an explicit incremental byte allowance derived from the plan, with
   the existing daily limit retained. Also present current free disk and database
   capacity, expected retained rows, and an operator-supervised time window.
   No defensible additional-byte amount exists from the current evidence alone.
4. A proposed first canary should stop after 15 minutes or its separately approved
   byte allowance, whichever occurs first; preserve the checkpoint on stop.
   Stop sooner on lost lease, a new gap, growing actionable queue age above 60
   seconds in three samples, or database/inbox admission limits. Require measured
   disk headroom for the proposed rows before starting; do not raise safety limits.
5. Verify monotonic committed checkpoint progress, source identity, unchanged
   replay seam, retained incidents/anchors, and idempotent inclusive replay.
   Completion requires evidence through the agreed sealed target and the
   subsequent live handoff, plus worker projection coverage; a green probe or an
   empty inbox alone is insufficient. Keep unresolved incidents open.

This is a review gate and proposed bounded procedure, not authorization to run
recovery. Preserve Development's remote Corpus dependency throughout; record
local ingestion lag and viewer-visible generation age separately.
