# The Social Wire iOS

Native SwiftUI client for The Social Wire.

## Development

Generate or refresh the Xcode project from **`apps/apple`**: `xcodegen generate` (sources use traditional **groups**, so new top-level files under **`SocialWire/`** need a regen to appear in Xcode).

### Cursor / VS Code + SweetPad

The repository root has no **`Package.swift`** (this target is Xcode + XcodeGen, not SPM). At the repo root the Swift VS Code extension’s **“Swift: Build All”** runs **`swift build`** and fails with *Could not find Package.swift*. Use **SweetPad: Build / Build & Run** instead, selecting **`apps/apple/The Social Wire.xcodeproj`** when needed.

For **`services/gateway`**, **`services/appview`**, or **`services/appview-worker`** Swift Package Manager work inside the same window, temporarily set **`swift.disableSwiftPackageManagerIntegration`** to **`false`** in your user settings, or open the service directory as its own window / multi-root workspace entry.

## Project Structure

```
apps/apple/
  project.yml                    # XcodeGen source for The Social Wire.xcodeproj
  The Social Wire.xcodeproj/      # Generated Xcode project (targets still named SocialWire for module/binary)
  SocialWire/
    App/
      SocialWireApp.swift         # @main entry point + SwiftData container
      SocialWireAppModel.swift    # Reader, sidebar, gateway, and mutation state
    Views/
      RootView.swift              # Restores OAuth and routes to login or reader
      LoginView.swift             # Handle input + signIn
      MainSplitView.swift         # Responsive split view / horizontal pager
      ReaderSidebarColumn.swift   # Lists, publications, and saved-link sidebar
      PublicationsPaneView.swift # Compact publications / saved-link pane
      EntryList/                  # Article list and rows
      EntryDetailView.swift       # Reader using HTMLWebView
      SavedLinks/                 # Saved-link rows, detail, chip, and toolbar
    Services/
      ATProtoOAuthService.swift   # Discovery + PAR + PKCE + DPoP OAuth
      Gateway/                    # Social Wire and L@tr gateway clients/DTOs
      PDSRecordService.swift      # Viewer-PDS preferences and L@tr records
      PublicationService.swift    # Author/viewer repo operations and social actions
      XRPCClient.swift            # Authenticated PDS XRPC transport
    Persistence/
      ReaderCacheCoordinator.swift # SwiftData reader cache
      ReaderCache/                 # SwiftData cache models and stack
    Utilities/
      ATProtoOAuthConfig.swift    # Client metadata + native redirect pairing
      KeychainStore.swift         # OAuth token/key persistence
  SocialWireTests/
    *.swift                       # Swift Testing suites
```

## Gateway & Thin AppView

The app uses **`SocialWireGatewayClient`** against **`SocialWireAPIEnvironment.baseURL`** for:

| Route | Purpose |
|-------|---------|
| `GET /v1/appview/bootstrap-stream` | Progressive NDJSON initial reader load |
| `GET /v1/publications/sidebar` | Sidebar projection |
| `GET /v1/sync/preferences` | Account preferences envelope (ETag-aware) |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| `/v1/appview/feed`, `/entries`, `/entry` | Aggregate/scoped lists and flat entry detail |
| Other `/v1/appview/*` | Unread counts, read marks, enroll, mark-all-read, purge |
| `/v1/publications/*` | Sidebar refresh/resolve plus folder, preference, and subscription PDS write-through |

### AppView reader path

The current reader uses AppView routes while they are available. `SocialWireAppModel` loads entry lists from `/v1/appview/feed` or `/entries`, and detail from `/v1/appview/entry`; there is no author-PDS detail fallback in normal article navigation.

| Behaviour | Implementation |
|-----------|----------------|
| Entry lists | `SocialWireGatewayClient.fetchAppViewEntries` |
| Aggregate lists | `SocialWireGatewayClient.fetchAggregateAppViewFeed` |
| Entry detail | `SocialWireGatewayClient.fetchAppViewEntryDetail` |
| Mark read / unread | AppView read-mark routes with local optimistic state |
| After discovery | `gateway.enrollAuthors` (fire-and-forget) |
| Privacy | With `SOCIALWIRE_USE_THIN_APPVIEW` compiled in, Profile → **Purge Indexed Data** calls `DELETE /v1/appview/privacy/purge` |

The backend requires **`ENABLE_THIN_APPVIEW=true`**, a running worker, and applied database migrations. Test on **`api.testing.thesocialwire.app`** before production.

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## ATProto OAuth Setup

The app signs in with the ATProto OAuth authorization-code flow, PKCE (`S256`), PAR, and DPoP via `ASWebAuthenticationSession`:

1. Resolve a handle with public `com.atproto.identity.resolveHandle`, then resolve the account PDS from its DID document.
2. Fetch `{pds}/.well-known/oauth-protected-resource`, follow its authorization-server issuer, and fetch `{issuer}/.well-known/oauth-authorization-server`.
3. POST the full authorization request to the discovered `pushed_authorization_request_endpoint`. PAR and token requests include DPoP proofs and retry a nonce challenge up to three times.
4. Open the discovered `authorization_endpoint` with only `client_id` and the returned `request_uri`.
5. Receive the code on **`{reversed-client-id-host}:/oauth/callback`**, then exchange and refresh tokens at the discovered `token_endpoint`.

The scope includes Social Wire folders/preferences, Bluesky social actions, L@tr records, Skyreader subscriptions, and standard.site/user-input permission sets. The refresh token, current access token, token endpoint, and DPoP key are stored in Keychain.

Source of truth: [`SocialWire/Services/ATProtoOAuthService.swift`](SocialWire/Services/ATProtoOAuthService.swift).

### Required URL Scheme

Register URL types in **Info.plist** (generated from [`project.yml`](project.yml)):

| Metadata host | Scheme |
|---------------|--------|
| `api.thesocialwire.app` | `app.thesocialwire.api` |
| `api.testing.thesocialwire.app` | `app.thesocialwire.testing.api` |
| `thesocialwire.app` | `app.thesocialwire` |

Callback path: `/oauth/callback` (e.g. `app.thesocialwire.api:/oauth/callback`).

### Running tests

In Xcode: **Product → Test** (Cmd+U).

CLI:

```sh
xcodebuild test \
  -project "The Social Wire.xcodeproj" \
  -scheme SocialWire \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

See [docs/test-plans/apple.md](../../docs/test-plans/apple.md).

## Reader navigation

- **iPhone / compact width:** a page-style horizontal `TabView`. Subscribed and Following use **Lists → Publications → Articles → Reader**. Read Later and Archive use **Lists → Saved Links → Reader** with contiguous three-pane tags.
- **iPad / regular width:** `NavigationSplitView` uses three columns for Subscribed/Following (combined lists/publications sidebar, articles, reader) and two for Read Later/Archive (combined lists/saved-links sidebar, reader).
- Reader chrome is hosted once by `MainSplitView`: profile, refresh, and scoped **Mark All As Read** actions are in the toolbar. Feed sources show an **All / Unread** segmented filter; saved-link sources do not.
- Read Later and Archive use L@tr saved links. New saves go through the L@tr gateway proxy; list/archive/unarchive/delete use viewer-PDS records in the current app model.

## OAuth client metadata (production vs preview)

The resolver currently uses `https://public.api.bsky.app` for handles and `https://plc.directory` for DID documents. The OAuth `client_id` defaults to `SocialWireAPIEnvironment.iosClientMetadataURL`. An **`ATProtoOAuthClientID`** string in the app's Info dictionary overrides that URL for tunnels or previews.

For alternate metadata during development, you can:

**A. Next.js / Vercel** — Deploy **`apps/web`** to a **Vercel preview** (or staging host) so `ios-client-metadata.json` is reachable over HTTPS, then follow the steps below using that URL.

**B. Swift gateway (local + tunnel)** — Run **`services/gateway`** (`APP_ENV=local swift run Gateway`). Expose it with **ngrok** (or similar). For **`/ios-client-metadata.json`**, set **`OAUTH_IOS_METADATA_ORIGIN`** when **`Host`/forwarded headers** do not match the tunnel URL (**`OAUTH_PUBLIC_ORIGIN`** applies only to web **`/oauth-client-metadata.json`**). Then use `https://<tunnel>/ios-client-metadata.json` as `ATProtoOAuthClientID`.

Then:

1. Ensure **client metadata** matches that URL: for Vercel/Next, deploy a matching `public/ios-client-metadata.json`; for Swift Gateway, `GET /ios-client-metadata.json` returns `redirect_uris` derived from **`client_id` host labels reversed** (same rule ATProto validates).
2. In the iOS target **Info** plist, add **`ATProtoOAuthClientID`** (string) with that same metadata URL.
3. Under **URL Types**, include every scheme the app uses: production API metadata → **`app.thesocialwire.api`**; testing API → **`app.thesocialwire.testing.api`**; marketing-site metadata (`thesocialwire.app`) → **`app.thesocialwire`** (see generated **URL Types** in [`project.yml`](project.yml)).

With no plist override, the app uses **`SocialWireAPIEnvironment`**: Release uses **`https://api.thesocialwire.app/ios-client-metadata.json`**; Debug and the XcodeGen **Beta** configuration use **`https://api.testing.thesocialwire.app/...`** and scheme **`app.thesocialwire.testing.api`**. `project.yml` adds `SOCIALWIRE_TESTING_API` to Beta automatically.

**Archives**: use scheme **SocialWire-TestFlight** (Beta) for TestFlight; **SocialWire** (Release) for App Store.
