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

Eligible JSON queries and procedures use the Lexicon-defined
`/xrpc/app.thesocialwire.*` surface through `SocialWireXRPCMethod`. The table
below separates those XRPC calls from the intentional HTTP-only stream/cache
surfaces and direct viewer-PDS writes.

| Surface | Purpose |
|-------|---------|
| `GET /v1/appview/bootstrap-stream` | Progressive NDJSON initial reader load |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| `/xrpc/app.thesocialwire.appview.*` | Feed, entry, unread, read-mark, enroll, mark-all-read, and purge APIs |
| `/xrpc/app.thesocialwire.publication.*` | Sidebar projection, refresh, and publication resolution |
| `/xrpc/app.thesocialwire.sync.getPreferences` | Account preferences envelope (ETag-aware) |
| Viewer PDS `com.atproto.repo.*` | Folder, publication preference, standard.site subscription, and Skyreader subscription records |

### AppView reader path

The current reader uses AppView routes while they are available.
`SocialWireAppModel` loads entry lists and detail through the corresponding
AppView XRPC methods; there is no author-PDS detail fallback in normal article
navigation.

| Behaviour | Implementation |
|-----------|----------------|
| Entry lists | `SocialWireGatewayClient.fetchAppViewEntries` |
| Aggregate lists | `SocialWireGatewayClient.fetchAggregateAppViewFeed` |
| Entry detail | `SocialWireGatewayClient.fetchAppViewEntryDetail` |
| Mark read / unread | AppView read-mark routes with local optimistic state |
| After discovery | `gateway.enrollAuthors` (fire-and-forget) |
| Privacy | With `SOCIALWIRE_USE_THIN_APPVIEW` compiled in, Profile → **Purge Indexed Data** calls `app.thesocialwire.appview.purgeViewerData`; it currently removes explicit read marks and unread overrides only |

The backend requires **`ENABLE_THIN_APPVIEW=true`**, a running worker, and applied database migrations. The testing and production API domains are stable custom domains for their Railway Gateway services; test on **`api.testing.thesocialwire.app`** before production.

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## ATProto OAuth Setup

The app signs in with the ATProto OAuth authorization-code flow, PKCE (`S256`), PAR, and DPoP via `ASWebAuthenticationSession`:

1. Resolve a handle with public `com.atproto.identity.resolveHandle`, then resolve the account PDS from its DID document.
2. Fetch `{pds}/.well-known/oauth-protected-resource`, follow its authorization-server issuer, and fetch `{issuer}/.well-known/oauth-authorization-server`.
3. POST the full authorization request to the discovered `pushed_authorization_request_endpoint`. PAR and token requests include DPoP proofs and retry a nonce challenge up to three times.
4. Open the discovered `authorization_endpoint` with only `client_id` and the returned `request_uri`.
5. Receive the code on **`{reversed-client-id-host}:/oauth/callback`**, then exchange and refresh tokens at the discovered `token_endpoint`.

The scope includes Social Wire folders/preferences, Bluesky social actions and viewer-moderation reads, L@tr records, Skyreader subscriptions, and standard.site/user-input permission sets. The refresh token, current access token, token endpoint, and DPoP key are stored in Keychain. Existing sessions must reauthenticate before viewer-aware moderation can be applied.

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

- **iPhone / compact width:** a page-style horizontal `TabView`. Subscribed and Following use **Lists → Publications → Articles → Reader**. The Wire uses **Lists → Articles → Reader**. Read Later and Archive use **Lists → Saved Links → Reader** with contiguous three-pane tags.
- **iPad / regular width:** `NavigationSplitView` uses three columns for The Wire and Subscribed/Following (combined lists/publications sidebar, articles, reader) and two for Read Later/Archive (combined lists/saved-links sidebar, reader).
- Reader chrome is hosted once by `MainSplitView`: profile, refresh, and scoped **Mark All As Read** actions are in the toolbar. Subscribed and Following show an **All / Unread** segmented filter; The Wire and saved-link sources do not.
- The Wire is capability-gated by `app.thesocialwire.discovery.getFeedCatalog`, uses viewer-scoped SwiftData page/detail caches, and never participates in unread state, read actions, or feed-display PDS preferences.
- Read Later and Archive use `link.latr.bookmarks.*` through the Social Wire Gateway for list/save/archive/unarchive/delete and lazy legacy migration.

## OAuth client metadata (production vs development)

The resolver currently uses `https://public.api.bsky.app` for handles and `https://plc.directory` for DID documents. The OAuth `client_id` defaults to `SocialWireAPIEnvironment.iosClientMetadataURL`. An **`ATProtoOAuthClientID`** string in the app's Info dictionary overrides that URL for local tunnels or another explicitly registered host.

Normal builds use Gateway metadata on the Railway custom domains:

| Build | Client metadata | Redirect scheme |
|-------|-----------------|-----------------|
| Debug / Beta | `https://api.testing.thesocialwire.app/ios-client-metadata.json` | `app.thesocialwire.testing.api` |
| Release | `https://api.thesocialwire.app/ios-client-metadata.json` | `app.thesocialwire.api` |

Generated `*.up.railway.app` domains are deployment diagnostics, not native OAuth identities. Keeping the custom domains stable avoids adding a new reversed-host URL scheme for every deployment.

For a local Gateway tunnel, run **`services/gateway`** with `APP_ENV=dev` and an
isolated disposable Postgres `DATABASE_URL`, then expose it over HTTPS. The
current shared Operations environment guard rejects `APP_ENV=local` even though
a SQLite backend remains implemented. Set **`OAUTH_IOS_METADATA_ORIGIN`** when
forwarded host headers do not match the tunnel URL (`OAUTH_PUBLIC_ORIGIN`
applies only to web metadata), then:

1. Confirm Gateway `GET /ios-client-metadata.json` returns a `client_id` for that exact HTTPS host and a `redirect_uri` derived from its reversed host labels.
2. In the iOS target **Info** plist, add **`ATProtoOAuthClientID`** (string) with that same metadata URL.
3. Add the tunnel's reversed-host scheme under **URL Types** before testing. The checked-in schemes cover production API metadata → **`app.thesocialwire.api`**, testing API metadata → **`app.thesocialwire.testing.api`**, and marketing-site metadata → **`app.thesocialwire`** (see [`project.yml`](project.yml)).

With no plist override, the app uses **`SocialWireAPIEnvironment`**: Release uses **`https://api.thesocialwire.app/ios-client-metadata.json`**; Debug and the XcodeGen **Beta** configuration use **`https://api.testing.thesocialwire.app/...`** and scheme **`app.thesocialwire.testing.api`**. `project.yml` adds `SOCIALWIRE_TESTING_API` to Beta automatically.

**Archives**: use scheme **SocialWire-TestFlight** (Beta) for TestFlight; **SocialWire** (Release) for App Store.
