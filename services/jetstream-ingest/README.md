# Jetstream V2 durable ingress

This private Railway service uses Bluesky's official Go client to consume
Jetstream V2 from US West. It stages scope-filtered commits and tracked-repository
lifecycle events in PostgreSQL before advancing the matching V2 sequence
checkpoint. Charybdis drains the durable inbox separately.

The staging transaction reads current AppView scope directly from PostgreSQL.
Standard Site document and entry commits require a matching publication-author
scope. Skyreader and graph-subscription commits require a matching viewer feed
or publication scope. Read-state records are intentionally not consumed by V2;
authenticated AppView mutations own that projection. This database-current decision avoids relying
on the periodically refreshed lifecycle-event snapshot. A newly activated scope
is repaired from its PDS by enrollment/backfill, so an event concurrent with
scope activation cannot become the only copy of repository state.

Identity, account, and sync lifecycle events use the bounded in-memory union of
those same author/viewer roles and may lag a scope change by at most
`JETSTREAM_TRACKED_DID_REFRESH`. A newly activated repository is repaired from
its PDS after scope persistence; a recently retired repository's extra lifecycle
event cannot create visible content without a current publication scope.

Charybdis also terminalizes previously staged out-of-scope commits in bounded
batches as `filtered_scope`. Those rows retain the scope-policy version and
decision timestamp, are never reported as applied or reconciled, and advance the
checkpoint only through the normal terminal-prefix calculation. Never delete
inbox rows or edit a checkpoint manually to clear a backlog.

The SDK owns `planSnapshot`, authenticated archive downloads, HTTP Range/ETag
continuation, `Retry-After`, and the replay-to-live seam. The service treats
every SDK error as a restart boundary and resumes from the last transactionally
staged sequence, so a failed decode or download can never be skipped by a later
checkpoint.

The Wire lane also supports a bounded archive snapshot. It supplies both
`WithBeforeSeq` and `WithSnapshotOnly` to the pinned SDK, so the requested range
is `(JETSTREAM_BOOTSTRAP_AFTER_SEQ, JETSTREAM_REPLAY_BEFORE_SEQ]` and the client
cannot continue into a live subscription. A clean iterator close is accepted
only when SDK statistics prove the configured upper sequence is sealed, fully
planned, and has no residual gap. Completion is then written under the fenced
leader lease. Sparse and zero-match snapshots therefore have a durable restart
marker instead of downloading the same archive range again. A completed
snapshot remains ready with `snapshotComplete: true` and parks until shutdown;
it never becomes a live consumer.

PostgreSQL stores the immutable inclusive upper bound in `replay_before_seq`,
separately from the provider-reported `replay_sealed_seq`. Only exact completion
transitions `replay_state` to the terminal `snapshot_complete` value. The
database prevents changing a bounded generation's lower or upper identity and
prevents reopening a completed snapshot. `last_staged_seq` remains the highest
event actually written to the inbox; it is legitimately `NULL` when a completed
snapshot contained no matching events.

The worker binds the exact range under its fenced lease before making the first
archive request. This means a crash or operator config change is detected on
restart even when the interrupted range had not produced a matching event yet.

The publication-author-viewer lane keeps the existing default of four parallel
segment stripes. The Wire lane defaults to one resumable segment stream because
hosted replay is metered in bytes and may close a response when its quota is
temporarily exhausted. Single-stream mode preserves the bytes already received
and resumes at the exact next offset after `Retry-After`; striped mode retries a
part from its beginning after a short body. `JETSTREAM_SEGMENT_STRIPES` remains
an explicit override for either lane.

## Required Railway variables

- `APP_ENV=dev|prod`
- `DATABASE_URL=${{Postgres.DATABASE_URL}}`
- `JETSTREAM_API_KEY` — raw hosted replay key; never include `Bearer `.
- `JETSTREAM_BOOTSTRAP_AFTER_SEQ` — required when the configured source generation has no checkpoint; set it to one less than the prior generation's last staged seam for an inclusive duplicate overlap.

Bounded Wire snapshots additionally require all of:

- `JETSTREAM_PIPELINE_MODE=wire-global-v1`
- `JETSTREAM_SOURCE_GENERATION` — a new generation dedicated to this exact
  bounded range; never reuse the live Wire generation (whose default is
  `wire-global-v1`) or another completed generation.
- `JETSTREAM_BOOTSTRAP_AFTER_SEQ` — the exclusive lower sequence bound.
- `JETSTREAM_REPLAY_BEFORE_SEQ` — the inclusive upper sequence bound. Both
  bounds must fit PostgreSQL's signed 64-bit cursor range.
- `JETSTREAM_REPLAY_SNAPSHOT_ONLY=true` — required with the upper bound and
  rejected when the upper bound is absent.

Leaving both bounded-replay variables unset preserves the existing unbounded
publication-author-viewer and Wire behavior. Bounded replay is rejected for the
publication-author-viewer pipeline, protecting its active source generation,
fingerprint, and checkpoint.

### Development 24-hour and seven-day expansion

Measure exact Jetstream sequence boundaries before changing variables. If `L`
is the earliest sequence already covered by the current one-hour Wire corpus,
`S24` is the first sequence wanted for 24 hours, and `S7` is the first sequence
wanted for seven days, use two non-overlapping snapshots:

| Snapshot | `JETSTREAM_BOOTSTRAP_AFTER_SEQ` | `JETSTREAM_REPLAY_BEFORE_SEQ` |
| --- | ---: | ---: |
| Missing 24-hour range | `S24 - 1` | `L - 1` |
| Missing seven-day range | `S7 - 1` | `S24 - 1` |

Run each in Development with a distinct, descriptive source generation, for
example `wire-global-v1-dev-24h-snapshot-v1` and
`wire-global-v1-dev-7d-snapshot-v1`. Use a distinct leader lease name as well if
a bounded snapshot service runs alongside the live Wire service. Keep the Wire
collection set and scope policy unchanged so only the source generation and
checkpoint are isolated. Do not delete or edit the live Wire checkpoint, and do
not point the publication-author-viewer service at either snapshot generation.

After `/status` reports `snapshotComplete: true`, stop that snapshot service and
inspect its durable inbox/checkpoint before starting the next range. Reusing a
completed generation with different bounds fails closed on startup. To roll
back, stop the bounded service and retain its inbox, lease, and checkpoint for
diagnosis; the unbounded lanes require no variable changes.

The deployment defaults to:

- `JETSTREAM_HOST=jetstream.us-west.bsky.network`
- `JETSTREAM_SOURCE_GENERATION=jetstream-v2-us-west-v2`
- `JETSTREAM_REPLAY_INCIDENT_BYTES=5368709120`
- `JETSTREAM_REPLAY_DAILY_BYTES=26843545600`

Inbox retention is owned by Charybdis through its
`THIN_APPVIEW_INGESTION_INBOX_*` settings; this ingress service never expires
work that has not yet been projected or intentionally scope-filtered.

Change the source generation whenever the host, cursor kind, stream NSID,
collection filter, or stable scope-policy semantics change. The filter
fingerprint includes the `publication-author-viewer-v1` policy identifier;
dynamic author/viewer membership does not create a new generation. Startup
rejects a checkpoint whose saved identity does not exactly match its configured
generation and refuses to start a new generation without an explicit bootstrap
seam.

`GET /healthz` is liveness. `GET /startupz` succeeds after PostgreSQL connects.
`GET /readyz` is successful while PostgreSQL, the fenced leader lease, and the
V2 process are active. A replay-budget pause keeps the service ready so Railway
does not restart a healthy controlled pause; `GET /status` exposes the pause
plus non-secret cursor and progress state. Railway deploys against `/startupz`
so a replacement can stay alive while the previous replica releases its fenced
lease; the replacement retries acquisition and `/readyz` remains unavailable
until it becomes the active consumer.

### The Wire admission boundary

The Wire lane atomically checks `wire_ingestion_admission.retained_rows` before
staging a batch. `WIRE_INBOX_MAX_ROWS` defaults to 5,000,000, and
`WIRE_DATABASE_MAX_BYTES` defaults to 80 GiB as an emergency whole-database
ceiling. At either boundary the transaction rolls back, the checkpoint does not
advance, the subscription reconnects from its durable cursor after
`WIRE_ADMISSION_PAUSE`, and `/readyz` reports the backpressured row/byte evidence.
The publication-author-viewer lane does not use this boundary.

## Local verification

```sh
go test ./...
go vet ./...
```

The process requires the provider-neutral database migrations and a disposable
PostgreSQL database. Never use the hosted Development or Production database
for local integration tests.
