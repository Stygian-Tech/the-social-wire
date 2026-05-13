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
      ATProtoOAuthService.swift   # PKCE + DPoP OAuth, ASWebAuthenticationSession
      PDSClient.swift             # XRPC helpers (actor), models
    Utilities/
      KeychainWrapper.swift       # Secure refresh token storage
  SocialWireTests/
    KeychainWrapperTests.swift    # @Test macros, Swift Testing
    PDSClientTests.swift
```

## ATProto OAuth Setup

The app uses standard PKCE + Bearer token flow (Phase 1).
DPoP proof signing is scaffolded but deferred to Phase 1b.

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
| `ATPROTO_CLIENT_ID` | OAuth client metadata URL (default: `https://thesocialwire.com/client-metadata.json`) |

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
