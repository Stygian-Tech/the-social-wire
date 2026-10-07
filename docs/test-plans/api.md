# Gateway test plan

**Package:** `services/gateway`  
**Runner:** Go (`go test -race -p 1 ./...`)\
**CI:** `go-packages`

## Commands

```bash
cd services/gateway
go test -race -p 1 ./...
```

## Test layout

```
services/gateway/internal/gateway/
  route_inventory_test.go
  proxy_contract_test.go
  preferences_test.go
  postgres_test.go
```

Go authentication tests live in `packages/go/gatewaycore/` (DPoP, internal trust, OAuth policy). Shared Swift GatewayCore tests remain for native clients.

## Auth matrix (manual + automated)

| Case | Expected | Test |
|------|----------|------|
| No `Authorization` on protected `/xrpc/*` or `/v1/*` | 401 | Go GatewayCore auth tests |
| Missing / invalid DPoP | 401 | Go GatewayCore auth tests |
| Valid Bearer + DPoP | 200 on protected routes | Go Gateway auth-flow and proxy tests |

## Bruno (manual HTTP)

Import `services/gateway/bruno/` as a Bruno collection. Folders include
**Health**, **OAuth**, **Sync**, **Publications**, **AppView**, **XRPC**,
**Latr**, **Operations**, and **Telemetry**. Operations and AppView folders also
contain focused XRPC requests where applicable.

Populate `oauthAccessToken` and `dpopProof` from a real OAuth session. Never commit tokens.

## OpenAPI drift

`packages/spec/__tests__/openapi-routes.test.ts` asserts documented paths exist
in Gateway, GatewayCore, AppView, and Operations router sources and reverse-checks
every directly registered literal `/v1/*` path. The endpoint-manifest test
classifies every OpenAPI operation and validates XRPC NSID mappings. CI job:
**`spec`**.

## Manual verification

- [ ] `curl /health` returns 200
- [ ] `GET /oauth-client-metadata.json` matches web scopes
- [ ] Authenticated `GET /xrpc/app.thesocialwire.sync.getPreferences` with real token
- [ ] AppView proxy routes return data when `APPVIEW_BASE_URL` is set

## Related

- [AppView test plan](./appview.md)
- [Charybdis test plan](./worker.md)
