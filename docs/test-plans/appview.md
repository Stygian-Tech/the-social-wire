# AppView test plan

**Package:** `services/appview`  
**Runner:** Swift Testing (`swift test`)  
**CI:** `test-appview`

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
