# Apple (iOS) test plan

**Package:** `apps/apple`  
Xcode **Cmd+U** runs Swift Testing suites (`import Testing`, `@Test`, `#expect`) — not XCTest.  
**CI:** Local only — Xcode Cloud and macOS GitHub Actions are **out of scope** for this repo (configure separately).

## Commands

```bash
cd apps/apple
xcodegen generate   # if project.yml changed

# From Xcode: Product → Test (Cmd+U)
# Or CLI:
xcodebuild test \
  -project "The Social Wire.xcodeproj" \
  -scheme SocialWire \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Use scheme **SocialWire-TestFlight** for TestFlight builds; **SocialWire** for App Store.

## Test layout

```
apps/apple/SocialWireTests/
  OAuthTests.swift
  SocialWireUtilityTests.swift
  PublicationSubscriptionMatchTests.swift
  ReaderCacheCoordinatorTests.swift
  SocialWireGatewayClientTests.swift
  ATProtoOAuthServiceTests.swift
  PDSRecordServiceTests.swift
  PublicationServiceTests.swift
  LatrGatewayClientTests.swift
  ReaderParityUtilityTests.swift
```

## API environment

| Build | Gateway |
|-------|---------|
| Debug | `https://api.testing.thesocialwire.app` |
| Release | `https://api.thesocialwire.app` |
| TestFlight (Release, no DEBUG) | Set `SOCIALWIRE_TESTING_API` for testing host |

## Manual OAuth checklist

- [ ] `client_id` matches hosted `ios-client-metadata.json` for active API host
- [ ] URL scheme matches reversed FQDN (e.g. `app.thesocialwire.api:/oauth/callback`)
- [ ] Sign in completes; Keychain holds refresh token
- [ ] Gateway sync preferences load after auth
- [ ] Thin AppView lists load when `SOCIALWIRE_USE_THIN_APPVIEW` is set

## Components / views

SwiftUI views are not unit-tested. Verify compact pager, sidebar, and reader chrome manually on iPhone and iPad simulators.

## Web parity matrix

Functional parity with `apps/web` (native SwiftUI chrome; not pixel-matched layouts). Status reflects the iOS Web Parity implementation.

| Area | Web reference | iOS owner | Parity status |
|------|---------------|-----------|---------------|
| Initial load | `bootstrapStreamClient.ts` | `SocialWireAppModel`, `BootstrapStreamModels.swift` | Done — NDJSON bootstrap stream, cache-first sidebar |
| Sidebar tabs | `AppSidebar.tsx` | `ReaderSidebarColumn`, `PublicationsPaneView` | Done — Subscribed / Following, folders, expand keys |
| Add publication | `AddPublicationDialog.tsx` | `AddPublicationView` | Done — Gateway resolve + subscribe |
| Entry list / pagination | `useEntries.ts` | `SocialWireAppModel.loadEntries` | Done — AppView entries + cursor |
| All / Unread filter | `ReadArticleFilterBar.tsx` | `ReaderShellChrome` | Done — deferred mark-read on Unread |
| Unread badges | `effectivePublicationUnreadCount` | `EffectiveUnreadCount`, `SocialWireAppModel.displayUnreadCount` | Done — server baseline reconciled with cached rows and local read state |
| Mark all read | `useCachedBulkReadActions.ts` | `SocialWireAppModel.markRead(for:)` | Done — scoped `.alert` confirmation |
| Read-state sync | `useCrossClientReadSync.ts` | `syncCrossClientReadState` | Done — foreground PDS merge + unread refresh |
| L@tr saves list | `useLatrMergedHttpsSaves` | `PDSRecordService.listMergedLatrSaves` | Done — via Social Wire Gateway `/v1/latr/saves` proxy |
| L@tr mutations | `useLatrSaved.ts` | `LatrGatewayClient`, `SocialWireAppModel` | Done — optimistic archive/delete/unarchive |
| Saved / Archive UI | `SavedLinksBrowser.tsx` | `SavedLinksListContent`, `SavedLinkDetailView` | Done — publication chip, embed URL, optimistic mutations |
| Article presentation | `entryArticlePresentation.ts` | `ArticlePresentationResolver`, `EntryDetailView` | Done — HTML vs web preview with per-entry lock |
| Feed social actions | `EntrySocialToolbar.tsx` | `ArticleToolbar`, `SavedLinkToolbar` | Done — Reply/Like/Repost/Quote on feed and saved Bluesky subjects |
| Read-later settings | `/saved/settings` | `SettingsView`, `ReadLaterServiceCatalog` | Done — L@tr Link functional; third-party prefs only |
| L@tr credentials | Vercel `/api/latr-gateway` (`LATR_GATEWAY_*`) | Social Wire Gateway `/v1/latr/*` (`LATR_IOS_PROXY_*`) | Done — secrets server-side only |

### L@tr Gateway transport

iOS must **not** ship L@tr API credentials. Requests go to `SocialWireAPIEnvironment.baseURL` (`/v1/latr/saves*`). The client sends:

- `Authorization` + gateway-bound `DPoP` (Social Wire Gateway `htu`)
- `X-Latr-Gateway-DPoP` (external L@tr Gateway `htu`; forwarded as outbound `DPoP`)
- `X-ATProto-Upstream-DPoP` (PDS write-through)

The **Social Wire Gateway** injects L@tr credentials from **`LATR_IOS_PROXY_URL`**, **`LATR_IOS_PROXY_CLIENT_ID`**, **`LATR_IOS_PROXY_API_KEY`**, or **`LATR_IOS_PROXY_CLIENT_CREDENTIAL`** on Fly/runtime secrets. These are separate from the **web** Vercel proxy secrets (`LATR_GATEWAY_*` on the Next.js host). Legacy `LATR_GATEWAY_*` names on the gateway are deprecated aliases.

## Related

- [apps/apple/README.md](../../apps/apple/README.md)
- [docs/wiki/Apple-client.md](../wiki/Apple-client.md)
- [docs/test-plans/web.md](./web.md)
