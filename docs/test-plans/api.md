# API test plan

**Package:** `services/api`  
**Runner:** Swift Testing (`swift test`)  
**CI:** `test-api`

## Commands

```bash
cd services/api
swift test
```

## Test layout

```
services/api/Tests/AppTests/
  AppConfigTests.swift
  AppEnvironmentLoaderTests.swift
  DiscoveryChainTests.swift
  DPoPProofVerifierTests.swift
  HTMLSanitizerTests.swift
  SQLiteCacheTests.swift
  HTTPRouteContractTests.swift
  WebOAuthClientMetadataTests.swift
  IosOAuthClientMetadataTests.swift
  WebOAuthScopesParityTests.swift
  OAuthAccessTokenVerifierTests.swift
  ATProtoAuthMiddlewareTests.swift
  OAuthGatewayClientPolicyTests.swift
  ThinAppViewRoutesTests.swift
  ThinAppViewEnrollServiceTests.swift
  PreferenceSyncServiceTests.swift
  ATProtoPdsResolutionTests.swift
```

## Auth matrix (manual + automated)

| Case | Expected | Test |
|------|----------|------|
| No `Authorization` on `/v1/*` | 401 | `ATProtoAuthMiddlewareTests` |
| Missing / invalid DPoP | 401 | `ATProtoAuthMiddlewareTests` |
| Expired JWT | 401 | `OAuthAccessTokenVerifierTests` |
| Wrong audience | 401 | `OAuthAccessTokenVerifierTests` |
| Unknown client when `OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT=true` | 403 | `OAuthGatewayClientPolicyTests` |
| Valid Bearer + DPoP | 200 on protected routes | `HTTPRouteContractTests`, `ThinAppViewRoutesTests` |

## Bruno (manual HTTP)

Import `services/api/bruno/` as a Bruno collection. Folders: **Health**, **OAuth**, **Sync**, **AppView**, **Legacy**.

Populate `oauthAccessToken` and `dpopProof` from a real OAuth session. Never commit tokens.

## OpenAPI drift

`packages/spec/__tests__/openapi-routes.test.ts` asserts documented paths exist in `services/api/Sources/App/**/*.swift`. CI job: **`test-spec`** (also runs when API route sources change).

## Feature flags in tests

- `ENABLE_THIN_APPVIEW=true` — Thin AppView route suites use SQLite backend
- `ENABLE_LEGACY_CONTENT_API` — legacy discovery/content routes (contract tests only when flag on)

## Manual verification

- [ ] `curl /health` returns 200
- [ ] `GET /oauth/client-metadata.json` matches web scopes
- [ ] Authenticated `GET /v1/sync/preferences` with real token
- [ ] AppView enroll + timeline when worker is running
