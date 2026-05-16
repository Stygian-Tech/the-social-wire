# The Social Wire — Apple

SwiftUI client for The Social Wire, targeting iOS 17+ (iPhone + iPad).

## Prerequisites

- Xcode 16+ (Swift 6.1)
- iOS 17+ deployment target
- An ATProto account (Bluesky or any PDS)

## Project Structure

```
apps/apple/
  project.yml                    # XcodeGen source for SocialWire.xcodeproj
  SocialWire.xcodeproj/           # Generated Xcode project
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

## ATProto OAuth Setup

The app signs in with **OAuth 2.0 authorization code + PKCE** (`code_challenge_method=S256`) via `ASWebAuthenticationSession`.

- **Authorize**: opens `{pds}/oauth/authorize` with `client_id`, `redirect_uri`, PKCE challenge, and a scope list (today limited to `atproto` plus Social Wire folder/publication prefs collections — narrower than the web client until parity work lands).
- **Callback**: `thesocialwire://oauth/callback` delivers `code` → exchanged over **`POST {pds}/oauth/token`** with `grant_type=authorization_code`, PKCE verifier, `redirect_uri`, and `client_id`.
- **Refresh**: `POST {pds}/oauth/token` with `grant_type=refresh_token`; refresh token lives in Keychain.

DPoP proofs are **not** attached to token requests in this codebase yet (tokens may still be DPoP-bound depending on PDS policy—the Swift client does not implement the proof headers here).

Source of truth: [`SocialWire/Services/ATProtoOAuthService.swift`](SocialWire/Services/ATProtoOAuthService.swift) (note: file-level comments may still mention DPoP; behaviour matches this README).

### Required URL Scheme

Add `thesocialwire` as a URL scheme in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>thesocialwire</string>
    </array>
  </dict>
</array>
```

### Environment Variables (via Xcode scheme)

| Variable | Description |
|----------|-------------|
| `ATPROTO_PLC_URL` | PLC directory URL (default: `https://plc.directory`) |
| `ATPROTO_CLIENT_ID` | Discoverable OAuth **`client_id`** URL used as `client_id` in authorize/token requests (code fallback: `https://thesocialwire.com/client-metadata.json`). Prefer aligning with hosted prod (`https://thesocialwire.app/client-metadata.json`, same origin as [`client-metadata.json`](../../apps/web/public/client-metadata.json)) or whichever **`ios-client-metadata.json`** / tunnel metadata URL your deployment publishes — mismatched `client_id`/redirect URIs break OAuth. |
| `ATPROTO_APPVIEW_PUBLIC` | Optional Bluesky App View base for handle resolution (default `https://public.api.bsky.app`). |

## Keychain Entitlement

The app stores the ATProto refresh token in the Keychain.
Ensure the `Keychain Sharing` entitlement is configured in Xcode
(even without a shared access group — required for Keychain access on device).

## Running Tests

```
cd apps/apple && xcodegen generate
Cmd+U in Xcode
```

Tests use the **Swift Testing** framework (`@Test`, `#expect`, `#require`).

## Architecture

- `ATProtoOAuthService` — `@MainActor ObservableObject` that owns the `AuthSession`. All OAuth state transitions (sign-in, callback, refresh, sign-out) go through this service.
- `PDSClient` — `actor` for authenticated user PDS records plus public ATProto discovery/content reads.
- `MainViewModel` — `@MainActor ObservableObject` that coordinates the three-column split view.

### Data Flow

```
ATProtoOAuthService
  └─ AuthSession { did, pdsURL, accessToken, refreshToken }
       └─ PDSClient
            ├─ User PDS → com.thesocialwire.folder + com.thesocialwire.publicationPrefs
            └─ Public ATProto XRPC → follows + site.standard.entry records
```

User organisation data (folders, publication prefs) is stored on the user's own PDS.
Discovery and content reads go directly to ATProto XRPC endpoints.
