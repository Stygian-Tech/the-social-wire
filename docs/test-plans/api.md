# Gateway test plan

**Package:** `services/gateway`  
**Runner:** Swift Testing (`swift test`)  
**CI:** `test-gateway`

## Commands

```bash
cd services/gateway
swift test
```

## Test layout

```
services/gateway/Tests/GatewayTests/
  GatewaySmokeTests.swift
  HTTPRouteContractTests.swift
  PreferenceSyncServiceTests.swift
  SQLiteCacheTests.swift
```

GatewayCore tests live in `packages/swift/GatewayCore/Tests/` (DPoP, internal trust, OAuth policy).

## Auth matrix (manual + automated)

| Case | Expected | Test |
|------|----------|------|
| No `Authorization` on `/v1/*` | 401 | GatewayCore middleware tests |
| Missing / invalid DPoP | 401 | GatewayCore middleware tests |
| Valid Bearer + DPoP | 200 on protected routes | `HTTPRouteContractTests` |

## Bruno (manual HTTP)

Import `services/gateway/bruno/` as a Bruno collection. Folders: **Health**, **OAuth**, **Sync**, **Publications**, **Reader**, **AppView** (proxy smoke).

Populate `oauthAccessToken` and `dpopProof` from a real OAuth session. Never commit tokens.

## OpenAPI drift

`packages/spec/__tests__/openapi-routes.test.ts` asserts documented paths exist in gateway, GatewayCore, and appview router sources. CI job: **`test-spec`**.

## Manual verification

- [ ] `curl /health` returns 200
- [ ] `GET /oauth/client-metadata.json` matches web scopes
- [ ] Authenticated `GET /v1/sync/preferences` with real token
- [ ] AppView proxy routes return data when `APPVIEW_BASE_URL` is set

## Related

- [AppView test plan](./appview.md)
- [AppView worker test plan](./worker.md)
