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

## Related

- [apps/apple/README.md](../../apps/apple/README.md)
- [docs/wiki/Apple-client.md](../wiki/Apple-client.md)
