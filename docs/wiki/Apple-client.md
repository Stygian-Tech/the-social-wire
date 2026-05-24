# Apple client

SwiftUI app under `apps/apple`.

**Setup, OAuth, tests**

- [apps/apple/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/README.md)

Covers Xcode/XcodeGen, PKCE OAuth flow, URL scheme, API environment (`SocialWireAPIEnvironment`), and architecture overview.

## Gateway usage

The app calls **`SocialWireAPIEnvironment.baseURL`** for first-party accelerators:

| Route | Purpose |
|-------|---------|
| `GET /v1/appview/bootstrap-stream` | Progressive NDJSON initial reader load (same contract as web) |
| `GET /v1/publications/sidebar` | Sidebar projection (when not using bootstrap stream path) |
| `GET /v1/sync/preferences` | Account preferences envelope |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| **`/v1/appview/*`** | Entry lists, unread counts, read marks, enroll, mark-all-read, purge |
| **`/v1/publications/*`** | Folder/subscription write-through (gateway) |

Legacy `/discovery` and `/entries` require **`ENABLE_LEGACY_CONTENT_API`** — not the default iOS path.

## Thin AppView (optional)

Add **`SOCIALWIRE_USE_THIN_APPVIEW`** to the target’s **Active Compilation Conditions** (Debug / TestFlight / Release as needed).

When enabled:

- Initial load consumes bootstrap-stream NDJSON events
- `SocialWireGatewayClient.fetchAppViewEntries` loads entry lists
- Read/unread toggles dual-write to PDS and AppView
- Scoped **Mark All As Read** via `POST /v1/appview/mark-all-read`
- **Profile → Purge Indexed Data** calls `DELETE /v1/appview/privacy/purge`

Entry detail remains PDS-direct via `PublicationService.entryDetail`.

Test against **`api.testing.thesocialwire.app`** (`DEBUG` or `SOCIALWIRE_TESTING_API`) before production.

See [[Thin-AppView]].

## Testing

XCTest in `SocialWireTests/` — run **Cmd+U** in Xcode. See [apple test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md).

| Area | Tests |
|------|-------|
| OAuth / PKCE / API env | `OAuthTests`, `ATProtoOAuthServiceTests` |
| Utilities (AT-URI, keys, HTML) | `SocialWireUtilityTests` |
| Subscription matching | `PublicationSubscriptionMatchTests` |
| Reader cache | `ReaderCacheCoordinatorTests` |
| Gateway client | `SocialWireGatewayClientTests` |
| PDS / publications | `PDSRecordServiceTests`, `PublicationServiceTests` |
| SwiftUI views | Manual simulator verification |

Xcode Cloud is not configured in-repo.

## Related

- App entrypoint: [`SocialWireApp.swift`](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/SocialWire/App/SocialWireApp.swift)
- [[Service-API]] — gateway + appview deploy and env vars
