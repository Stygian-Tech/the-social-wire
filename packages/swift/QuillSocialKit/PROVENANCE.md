# Quill Social Source Snapshot

Copied from the local `quill-app/packages/swift/QuillKit` working tree based on commit `00e9d048f4aaee7289215a57f458797b72d029d6`.
ATProtoCore, Feeds, and Navigation originated from that snapshot. The imported SwiftUI views and supporting UI models come from `quill-app/apps/ios/Quill` at the same working-tree revision. Authentication remains owned by The Social Wire.

The snapshot includes existing uncommitted changes in `Sources/Feeds/PinnedFeedsModel.swift` and `Tests/FeedsTests/PinnedFeedsModelTests.swift`: duplicate feed identifiers are removed and stale mutation offsets are ignored, with matching regression coverage.

The package deployment minimums are iOS 18 and macOS 15. Native UI adaptations live in QuillSocialUI: availability fallbacks, Social Wire transport injection, account-scoped settings and seen-story state, complete route dispatch, and partial-thread publication recovery. Quill authentication, app identity, and CloudKit configuration are excluded. Original core and selected UI tests are retained alongside integration regressions.

No LICENSE, COPYING, or NOTICE file was present in the source repository at the time of this copy; this note does not grant or change licensing rights.
