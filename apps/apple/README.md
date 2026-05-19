# The Social Wire iOS

Native SwiftUI client for The Social Wire.

## Development

Generate or refresh the Xcode project from **`apps/apple`**: `xcodegen generate` (sources use traditional **groups**, so new top-level files under **`SocialWire/`** need a regen to appear in Xcode).

### Cursor / VS Code + SweetPad

The repository root has no **`Package.swift`** (this target is Xcode + XcodeGen, not SPM). At the repo root the Swift VS Code extension’s **“Swift: Build All”** runs **`swift build`** and fails with *Could not find Package.swift*. Use **SweetPad: Build / Build & Run** instead, after **SweetPad: Select Xcode workspace** if needed—the workspace default is **[`.vscode/settings.json`](../../.vscode/settings.json)** → **`apps/apple/The Social Wire.xcodeproj`**.

For **`services/api`** Swift Package Manager work inside the same window, temporarily set **`swift.disableSwiftPackageManagerIntegration`** to **`false`** in your user settings, or open **`services/api`** as its own window / multi-root workspace entry.

## Project Structure

```
apps/apple/
  project.yml                    # XcodeGen source for The Social Wire.xcodeproj
  The Social Wire.xcodeproj/      # Generated Xcode project (targets still named SocialWire for module/binary)
  SocialWire/
    App/
      SocialWireApp.swift         # @main entry point, ATProto OAuth callback handler
    Views/
      ContentView.swift           # Root: routes to LoginView or MainSplitView
      LoginView.swift             # Handle input + signIn
      MainSplitView.swift         # NavigationSplitView (3-column) + MainViewModel
      FolderListView.swift        # Sidebar: folders + publications
      EntryListView.swift         # Column 2: entry list
      EntryDetailView.swift       # Column 3: WKWebView HTML renderer
    Services/
      ATProtoOAuthService.swift   # PKCE OAuth + ASWebAuthenticationSession
      PDSClient.swift             # XRPC helpers (actor), models
    Utilities/
      KeychainWrapper.swift       # Secure refresh token storage
  SocialWireTests/
    KeychainWrapperTests.swift    # @Test macros, Swift Testing
    PDSClientTests.swift
```

## Gateway & Thin AppView

The app uses **`SocialWireGatewayClient`** against **`SocialWireAPIEnvironment.baseURL`** for:

| Route | Purpose |
|-------|---------|
| `GET /v1/sync/preferences` | Account preferences envelope (ETag-aware) |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| `/v1/appview/*` | Thin AppView (when compile flag on) |

### Thin AppView (optional)

Add **`SOCIALWIRE_USE_THIN_APPVIEW`** to the target's **Active Compilation Conditions** to route entry **lists** through the gateway. Entry **detail** stays on author PDS via `PublicationService`.

| Behaviour | Implementation |
|-----------|----------------|
| Entry lists | `SocialWireGatewayClient.fetchAppViewEntries` |
| Mark read / unread | PDS first, then write-through to gateway |
| After discovery | `gateway.enrollAuthors` (fire-and-forget) |
| Privacy | Profile → **Purge Indexed Data** → `DELETE /v1/appview/privacy/purge` |

Requires gateway **`ENABLE_THIN_APPVIEW=true`**, worker deploy, and Supabase migration. Test on **`api.testing.thesocialwire.app`** before production.

See [docs/architecture/appview.md](../../docs/architecture/appview.md) and [docs/wiki/Thin-AppView.md](../../docs/wiki/Thin-AppView.md).

## ATProto OAuth Setup

The app signs in with **OAuth 2.0 authorization code + PKCE** (`code_challenge_method=S256`) via `ASWebAuthenticationSession`.

- **Authorize**: opens `{pds}/oauth/authorize` with `client_id`, `redirect_uri`, PKCE challenge, and a scope list (today limited to `atproto` plus Social Wire folder/publication prefs collections — narrower than the web client until parity work lands).
- **Callback**: custom URL scheme **`{reversed-client_id-host}:/oauth/callback`** (e.g. `client_id` on `api.thesocialwire.app` → **`app.thesocialwire.api:/oauth/callback`**) delivers `code` → exchanged over **`POST {pds}/oauth/token`** with `grant_type=authorization_code`, PKCE verifier, `redirect_uri`, and `client_id`.
- **Refresh**: `POST {pds}/oauth/token` with `grant_type=refresh_token`; refresh token lives in Keychain.

DPoP proofs are **not** attached to token requests in this codebase yet (tokens may still be DPoP-bound depending on PDS policy—the Swift client does not implement the proof headers here).

Source of truth: [`SocialWire/Services/ATProtoOAuthService.swift`](SocialWire/Services/ATProtoOAuthService.swift) (note: file-level comments may still mention DPoP; behaviour matches this README).

### Required URL Scheme

```sh
xcodebuild test -scheme SocialWire -destination 'platform=iOS Simulator,id=<Simulator-UUID>'
```

## OAuth client metadata (production vs preview)

| Variable | Description |
|----------|-------------|
| `ATPROTO_PLC_URL` | PLC directory URL (default: `https://plc.directory`) |
| `ATPROTO_CLIENT_ID` | Discoverable OAuth **`client_id`** URL used as `client_id` in authorize/token requests (code fallback: `https://thesocialwire.com/client-metadata.json`). Prefer aligning with hosted prod (`https://thesocialwire.app/client-metadata.json`, same origin as [`client-metadata.json`](../../apps/web/public/client-metadata.json)) or whichever **`ios-client-metadata.json`** / tunnel metadata URL your deployment publishes — mismatched `client_id`/redirect URIs break OAuth. |
| `ATPROTO_APPVIEW_PUBLIC` | Optional Bluesky App View base for handle resolution (default `https://public.api.bsky.app`). |

Until that file is live on production, you can:

**A. Next.js / Vercel** — Deploy **`apps/web`** to a **Vercel preview** (or staging host) so `ios-client-metadata.json` is reachable over HTTPS, then follow the steps below using that URL.

**B. Swift API (local + tunnel)** — Run [`services/api`](../../services/api/README.md) (`APP_ENV=local swift run App`). Expose it with **ngrok** (or similar). For **`/ios-client-metadata.json`**, set **`OAUTH_IOS_METADATA_ORIGIN`** when **`Host`/forwarded headers** do not match the tunnel URL (**`OAUTH_PUBLIC_ORIGIN`** applies only to web **`/oauth/client-metadata.json`**). Then use `https://<tunnel>/ios-client-metadata.json` as `ATProtoOAuthClientID`.

Then:

1. Ensure **client metadata** matches that URL: for Vercel/Next, edit the deployed JSON; for Swift API, `GET /ios-client-metadata.json` returns `redirect_uris` derived from **`client_id` host labels reversed** (same rule ATProto validates).
2. In the iOS target **Info** plist, add **`ATProtoOAuthClientID`** (string) with that same metadata URL.
3. Under **URL Types**, include every scheme the app uses: production API metadata → **`app.thesocialwire.api`**; testing API → **`app.thesocialwire.testing.api`**; marketing-site metadata (`thesocialwire.app`) → **`app.thesocialwire`** (see generated **URL Types** in [`project.yml`](project.yml)).

With no plist override, the app uses **`SocialWireAPIEnvironment`**: **`https://api.thesocialwire.app/ios-client-metadata.json`** in Release; Debug and Beta (TestFlight) builds use **`https://api.testing.thesocialwire.app/...`** and scheme **`app.thesocialwire.testing.api`**.

**Archives**: use scheme **SocialWire-TestFlight** (Beta) for TestFlight; **SocialWire** (Release) for App Store.
