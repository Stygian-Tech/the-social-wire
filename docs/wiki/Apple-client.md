# Apple app

The native SwiftUI client supports iPhone and iPad on iOS/iPadOS 17 or later. The repository does not currently publish an App Store or TestFlight download URL, so this page documents the source build and the implemented client behavior.

## Navigation

- On iPhone, Subscribed and Following use **Lists → Publications → Articles → Reader**.
- Read Later and Archive use **Lists → Saved Links → Reader** with no article-list pane or All/Unread filter.
- On iPad, `NavigationSplitView` presents the same hierarchy in columns.
- The profile avatar opens **Profile**, which contains My Publications, Settings, Log Out, and Purge Indexed Data.

Pull to refresh gives subtle impact feedback. Confirmed saves, deletes, and mark-all-read actions give success feedback.

## Current Apple capabilities

- Add standard.site or RSS/Atom publications under Subscribed.
- Create/delete folders and organize subscribed publications.
- Filter feed articles by All or Unread and use scoped Mark All As Read.
- Save articles to L@tr Link; archive, unarchive, share, open, or delete saved links.
- Like, reply to, repost, quote, or share when the original article has a compatible social subject.
- Choose visible top-level lists and which list counts appear.
- Purge the signed-in viewer's explicit AppView read marks and unread overrides after confirmation. Bulk-read floors and other projection rows currently remain.

The web-only theme/font/RSS-reader controls, standard.site Recommend action, and UserInput feedback form are not currently exposed in the Apple UI.

## Developer setup

The Xcode/XcodeGen project lives under `apps/apple`; it is not a root Swift package.

```bash
cd apps/apple
xcodegen generate
open "The Social Wire.xcodeproj"
```

Use the `SocialWire` scheme for normal Debug/Release builds and `SocialWire-TestFlight` for the Beta/TestFlight configuration. New top-level Swift files may require regenerating the project.

Full setup: [apps/apple/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/README.md).

## Gateway usage

Eligible JSON queries and procedures use Lexicon-defined
`/xrpc/app.thesocialwire.*` methods. Streaming and cached-record adapters stay
HTTP, while user-owned publication records use standard XRPC directly on the
viewer PDS.

| Surface | Purpose |
|-------|---------|
| `GET /v1/appview/bootstrap-stream` | Progressive initial reader load |
| `GET /v1/pds/cache/record` | Cached single-record reads |
| `/xrpc/app.thesocialwire.appview.*` | Entry APIs, counts, read marks, enrollment, mark-all-read, and purge |
| `/xrpc/app.thesocialwire.publication.*` | Sidebar projection, refresh, and resolve |
| `/xrpc/app.thesocialwire.sync.getPreferences` | Account preferences envelope |
| Viewer PDS `com.atproto.repo.*` | Folders, publication preferences, and subscriptions |
| `/v1/latr/*` | L@tr list/save proxy; archive/unarchive/delete use direct viewer-PDS writes in the current app model |

The reader uses AppView for normal entry lists and detail. It does not fall back to an author-PDS body read during normal navigation. Current read state is AppView-backed with a local SwiftData cache; the client does not create `app.thesocialwire.entryReadState` PDS records.

## OAuth environments

Native sign-in follows protected-resource and authorization-server discovery, mandatory PAR, PKCE, and DPoP nonce retries. The client ID, metadata response, redirect URI, and registered URL scheme must match.

| Build | Metadata | Redirect scheme |
|-------|----------|-----------------|
| Debug / Beta | `https://api.testing.thesocialwire.app/ios-client-metadata.json` | `app.thesocialwire.testing.api` |
| Release | `https://api.thesocialwire.app/ios-client-metadata.json` | `app.thesocialwire.api` |

Generated Railway domains are diagnostics, not native OAuth identities. TestFlight is normally a Release-style archive unless the `SocialWire-TestFlight` Beta configuration supplies `SOCIALWIRE_TESTING_API`.

## Testing

Swift Testing suites under `apps/apple/SocialWireTests` run with **Cmd+U** or:

```bash
cd apps/apple
xcodebuild test \
  -project "The Social Wire.xcodeproj" \
  -scheme SocialWire \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

GitHub Actions runs the app's Swift Testing suite with code coverage on a macOS iOS Simulator. See the [Apple test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/apple.md).

Related: [[Getting-started]], [[Reading-and-organizing]], [[Account-settings-and-privacy]], [[Service-API]].
