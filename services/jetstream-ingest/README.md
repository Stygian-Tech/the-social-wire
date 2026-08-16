# Jetstream V2 durable ingress

This private Railway service uses Bluesky's official Go client to consume
Jetstream V2 from US West. It stages filtered commits and tracked-repository
lifecycle events in PostgreSQL before advancing the matching V2 sequence
checkpoint. Charybdis drains the durable inbox separately.

The SDK owns `planSnapshot`, authenticated archive downloads, HTTP Range/ETag
continuation, `Retry-After`, and the replay-to-live seam. The service treats
every SDK error as a restart boundary and resumes from the last transactionally
staged sequence, so a failed decode or download can never be skipped by a later
checkpoint.

## Required Railway variables

- `APP_ENV=dev|prod`
- `DATABASE_URL=${{Postgres.DATABASE_URL}}`
- `JETSTREAM_API_KEY` — raw hosted replay key; never include `Bearer `.

The deployment defaults to:

- `JETSTREAM_HOST=jetstream.us-west.bsky.network`
- `JETSTREAM_SOURCE_GENERATION=jetstream-v2-us-west-v1`
- `JETSTREAM_REPLAY_INCIDENT_BYTES=5368709120`
- `JETSTREAM_REPLAY_DAILY_BYTES=26843545600`

Inbox retention is owned by Charybdis through its
`THIN_APPVIEW_INGESTION_INBOX_*` settings; this ingress service never expires
work that has not yet been projected.

Change the source generation whenever the host, cursor kind, stream NSID, or
collection filter changes. Startup rejects a checkpoint whose saved identity
does not exactly match its configured generation.

`GET /healthz` is liveness. `GET /readyz` is successful while PostgreSQL, the
fenced leader lease, and the V2 process are active. A replay-budget pause keeps
the service ready so Railway does not restart a healthy controlled pause;
`GET /status` exposes the pause plus non-secret cursor and progress state.

## Local verification

```sh
go test ./...
go vet ./...
```

The process requires the provider-neutral database migrations and a disposable
PostgreSQL database. Never use the hosted Development or Production database
for local integration tests.
