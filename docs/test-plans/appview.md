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

Import `services/appview/bruno/` for direct AppView routes (sidebar, bootstrap stream, entries, enroll). In production, clients hit the same paths via the gateway proxy.

## Feature flags in tests

- `ENABLE_THIN_APPVIEW=true` — Thin AppView route suites use SQLite backend

## Manual verification

- [ ] `GET /v1/publications/sidebar` with authenticated token
- [ ] `GET /v1/appview/bootstrap-stream` streams NDJSON events
- [ ] Enroll + timeline when appview-worker is running

## Related

- [Gateway test plan](./api.md)
- [AppView worker test plan](./worker.md)
- [Thin AppView architecture](../architecture/appview.md)
