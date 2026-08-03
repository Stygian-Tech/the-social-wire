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
| **`/v1/appview/feed`, `/entries`, `/entry`** | Aggregate/scoped lists and flat entry detail |
| Other **`/v1/appview/*`** | Unread counts, read marks, enroll, mark-all-read, purge |
| **`/v1/publications/*`** | Sidebar refresh/resolve and folder/subscription PDS write-through |

Legacy `/discovery` and `/entries` require **`ENABLE_LEGACY_CONTENT_API`** — not the default iOS path.

## AppView reader path

The current `SocialWireAppModel` uses AppView routes while they are available:

- Initial load consumes bootstrap-stream NDJSON events
- `fetchAggregateAppViewFeed` / `fetchAppViewEntries` load entry lists
- `fetchAppViewEntryDetail` loads flat entry detail; normal article navigation has no author-PDS detail fallback
- Read/unread toggles write AppView read marks with local optimistic state
- Scoped **Mark All As Read** via `POST /v1/appview/mark-all-read`
- When `SOCIALWIRE_USE_THIN_APPVIEW` is compiled in, **Profile → Purge Indexed Data** calls `DELETE /v1/appview/privacy/purge`

Test against **`api.testing.thesocialwire.app`** (`DEBUG` or `SOCIALWIRE_TESTING_API`) before production. It and **`api.thesocialwire.app`** are the stable custom domains for the testing and production Railway Gateway services; generated Railway service domains are not native OAuth client IDs.

See [[Thin-AppView]].

## Testing

Swift Testing suites in `SocialWireTests/` run with **Cmd+U** in Xcode. See [apple test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md).

| Area | Tests |
|------|-------|
| OAuth / PKCE / API env | `OAuthTests`, `ATProtoOAuthServiceTests` |
| Utilities (AT-URI, keys, HTML) | `SocialWireUtilityTests` |
| Subscription matching | `PublicationSubscriptionMatchTests` |
| Reader cache | `ReaderCacheCoordinatorTests` |
| Gateway client | `SocialWireGatewayClientTests` |
| PDS / publications | `PDSRecordServiceTests`, `PublicationServiceTests` |
| Bootstrap stream | `BootstrapStreamNDJSONTests` |
| Saved-link publication matching | `SavedLinkPublicationResolverTests` |
| SwiftUI views | Manual simulator verification |

Xcode Cloud is not configured in-repo.

## OAuth

Native sign-in resolves the PDS, follows ATProto protected-resource and authorization-server metadata, submits a PKCE request through mandatory PAR, and exchanges/refreshes tokens at the discovered token endpoint. PAR and token requests carry DPoP proofs and retry nonce challenges. The native redirect is the reversed metadata host with one slash, such as `app.thesocialwire.api:/oauth/callback`.

`SocialWireAPIEnvironment.iosClientMetadataURL` is the default `client_id`; an `ATProtoOAuthClientID` Info value can override it. Debug and XcodeGen Beta builds use the testing API, while Release uses production.

Gateway `/ios-client-metadata.json` is authoritative for native OAuth. Its client ID, reversed-host redirect scheme, the app's registered URL type, and the active Railway custom domain must agree.

## Reader navigation and L@tr

- iPhone uses a page-style horizontal pager: Subscribed/Following are **Lists → Publications → Articles → Reader**; Read Later/Archive are **Lists → Saved Links → Reader**.
- iPad uses three columns for feed sources and two for saved-link sources.
- Shared reader chrome owns profile, refresh, scoped **Mark All As Read**, and the feed-only **All / Unread** filter.
- New L@tr saves use the Social Wire/L@tr gateway path. The current app model lists, archives, unarchives, and deletes saved records directly on the viewer PDS. There is no read-later provider selector.

## Related

- App entrypoint: [`SocialWireApp.swift`](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/SocialWire/App/SocialWireApp.swift)
- [[Service-API]] — gateway + appview deploy and env vars
