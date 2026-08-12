# AppView test plan

**Package:** `services/appview`  
**Runner:** Swift Testing (`swift test`)  
**CI:** `appview`

## Commands

```bash
cd services/appview
swift test
```

## Test layout

```
services/appview/Tests/AppViewTests/
  AppViewSmokeTests.swift
  BootstrapStreamSelectionTests.swift
  PublicationProjectionLogicTests.swift
  ThinAppViewEnrollServiceTests.swift
```

## Bruno (manual HTTP)

Import `services/appview/bruno/` for direct AppView routes (sidebar, bootstrap stream, aggregate/scoped feeds, flat entry detail, read marks, and enroll). In production, clients hit the same paths via the gateway proxy.

## Redis cache and coordination

```bash
cd packages/swift/SocialWireRedis
swift test

# CI supplies a pinned redis:8.2.8-alpine service for live integration coverage.
REDIS_INTEGRATION_URL=redis://127.0.0.1:6379 swift test
```

The integration suite covers PEXPIRE round trips, independent-client lease contention, owner-safe Lua release, SCAN/UNLINK invalidation, sorted-set ranking, and flush/rebuild behavior. Service suites cover stale-first projection responses, partial unread state, first-page read-state re-resolution, and fail-open cache selection.

## Feature flags in tests

- `ENABLE_THIN_APPVIEW=true` — Thin AppView route suites use SQLite backend

## Manual verification

- [ ] `GET /v1/publications/sidebar` with authenticated token
- [ ] `GET /v1/appview/bootstrap-stream` streams NDJSON events
- [ ] `GET /v1/appview/feed`, `/entries`, and `/entry` return the documented shapes
- [ ] Enroll `authorDids` and `feedUrls`, then confirm timelines while Charybdis is running

## Related

- [Gateway test plan](./api.md)
- [Charybdis test plan](./worker.md)
- [Thin AppView architecture](../architecture/appview.md)
