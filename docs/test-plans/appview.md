# AppView test plan

**Package:** `services/appview`  
**Runner:** Go (`go test -race -p 1 ./...`)\
**CI:** `go-packages`

## Commands

```bash
cd services/appview
go test -race -p 1 ./...
```

## Test layout

```
services/appview/internal/
  runtime/*_test.go
  reader/*_test.go
  publications/*_test.go
  readstate/*_test.go
  podcasts/*_test.go
```

## Bruno (manual HTTP)

Import `services/appview/bruno/` for direct AppView XRPC and compatibility routes
(sidebar, bootstrap stream, aggregate/scoped feeds, flat entry detail, read
marks, and enroll). In production, clients hit the same operations through the
gateway proxy.

## Redis cache and coordination

```bash
cd packages/swift/SocialWireRedis
swift test

# CI supplies a pinned redis:8.2.8-alpine service for live integration coverage.
REDIS_INTEGRATION_URL=redis://127.0.0.1:6379 swift test
```

The integration suite covers PEXPIRE round trips, independent-client lease contention, owner-safe Lua release, SCAN/UNLINK invalidation, sorted-set ranking, and flush/rebuild behavior. Service suites cover stale-first projection responses, partial unread state, first-page read-state re-resolution, and fail-open cache selection.

## Feature flags in tests

- `ENABLE_THIN_APPVIEW=true` — the Go host requires explicit PostgreSQL `DATABASE_URL`

## Manual verification

- [ ] `GET /xrpc/app.thesocialwire.publication.getSidebar` with authenticated token
- [ ] `GET /v1/appview/bootstrap-stream` streams NDJSON events
- [ ] AppView `getFeed`, `listEntries`, and `getEntry` XRPC queries return the documented shapes
- [ ] Enroll `authorDids` and `feedUrls`, then confirm timelines while Projection Pool is running

## Related

- [Gateway test plan](./api.md)
- [Charybdis test plan](./worker.md)
- [Thin AppView architecture](../architecture/appview.md)
