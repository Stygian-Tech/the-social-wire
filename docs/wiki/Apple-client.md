# Apple client

SwiftUI app under `apps/apple`.

**Setup, OAuth, tests**

- [apps/apple/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/README.md)

Covers Xcode/XcodeGen, PKCE OAuth flow, URL scheme, API environment (`SocialWireAPIEnvironment`), and architecture overview.

## Gateway usage

The app calls **`SocialWireAPIEnvironment.baseURL`** for first-party accelerators:

| Route | Purpose |
|-------|---------|
| `GET /v1/sync/preferences` | Account preferences envelope |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| **`/v1/appview/*`** | Thin AppView (when compile flag on) |

Legacy `/discovery` and `/entries` on the gateway require **`ENABLE_LEGACY_CONTENT_API`** — not the default iOS path.

## Thin AppView (optional)

Add **`SOCIALWIRE_USE_THIN_APPVIEW`** to the target’s **Active Compilation Conditions** (Debug / TestFlight / Release as needed).

When enabled:

- `SocialWireGatewayClient.fetchAppViewEntries` loads entry lists
- Read/unread toggles write-through after PDS `markRead` / `markUnread`
- `refreshAll` enrolls discovered author DIDs (fire-and-forget)
- **Profile → Purge Indexed Data** calls `DELETE /v1/appview/privacy/purge`

Entry detail remains PDS-direct via `PublicationService.entryDetail`.

Test against **`api.testing.thesocialwire.app`** (`DEBUG` or `SOCIALWIRE_TESTING_API`) before production.

See [[Thin-AppView]].

## Related

- App entrypoint: [`SocialWireApp.swift`](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/SocialWire/App/SocialWireApp.swift)
- [[Service-API]] — worker deploy and env vars
