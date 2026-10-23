# Native Media Prototype

Standalone SwiftUI app for TSW-225. It shares the web prototype's sample content and source mapping, with native navigation and AVKit playback. It does not modify or depend on the production Apple app, authenticate, or fetch live feeds.

Generate and build with XcodeGen and Xcode:

```sh
cd prototypes/media/ios
xcodegen generate
xcodebuild -project MediaPrototype.xcodeproj -scheme MediaPrototype -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/tsw-225-ios-build build
```

Install `/tmp/tsw-225-ios-build/Build/Products/Debug-iphonesimulator/MediaPrototype.app` on a Simulator. Bundle ID: `app.thesocialwire.media-prototype`.

All photographs and the CC0 sample video are bundled for repeatable demos. Source labels describe proposed adapters, not the provenance of the illustrative photographs. See the parent `lexicon-notes.md` for verified contracts and remaining integration work.
