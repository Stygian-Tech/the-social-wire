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

## Required Railway variables

- `APP_ENV=dev|prod`
- `DATABASE_URL=${{Postgres.DATABASE_URL}}`
- `JETSTREAM_API_KEY` — raw hosted replay key; never include `Bearer `.
- `JETSTREAM_BOOTSTRAP_AFTER_SEQ` — required when the configured source generation has no checkpoint; set it to one less than the prior generation's last staged seam for an inclusive duplicate overlap.

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

## Local verification

```sh
go test ./...
go vet ./...
```

The process requires the provider-neutral database migrations and a disposable
PostgreSQL database. Never use the hosted Development or Production database
for local integration tests.
