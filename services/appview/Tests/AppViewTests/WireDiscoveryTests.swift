import Foundation
import HTTPTypes
import Testing
import WireCore
@testable import AppView

@Suite("The Wire discovery serving")
struct WireDiscoveryTests {
  @Test("uses only the approved rollout modes")
  func rolloutModes() throws {
    for raw in ["off", "shadow", "api", "visible"] {
      let config = try WireDiscoveryConfig.fromEnvironment(["WIRE_FEED_MODE": raw])
      #expect(config.mode.rawValue == raw)
    }
    #expect(throws: WireDiscoveryConfigError.invalidMode("enabled")) {
      _ = try WireDiscoveryConfig.fromEnvironment(["WIRE_FEED_MODE": "enabled"])
    }
    #expect(!WireDiscoveryMode.off.servesAPI)
    #expect(!WireDiscoveryMode.shadow.servesAPI)
    #expect(WireDiscoveryMode.api.servesAPI)
    #expect(WireDiscoveryMode.visible.servesAPI)
    #expect(!WireDiscoveryMode.api.isVisible)
    #expect(WireDiscoveryMode.visible.isVisible)
  }

  @Test("viewer moderation is fresh for five minutes and usable for thirty")
  func moderationTTL() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let cache = WireViewerModerationCache()
    let snapshot = WireViewerModerationSnapshot(
      blockedDIDs: ["did:plc:blocked"],
      mutedDIDs: ["did:plc:muted"],
      mutedWords: ["spoiler"],
      fetchedAt: now
    )
    await cache.store(snapshot, viewerDID: "did:plc:viewer")
    #expect(await cache.fresh(viewerDID: "did:plc:viewer", now: now.addingTimeInterval(299)) != nil)
    #expect(await cache.fresh(viewerDID: "did:plc:viewer", now: now.addingTimeInterval(301)) == nil)
    #expect(await cache.usable(viewerDID: "did:plc:viewer", now: now.addingTimeInterval(1_799)) != nil)
    #expect(await cache.usable(viewerDID: "did:plc:viewer", now: now.addingTimeInterval(1_801)) == nil)
  }

  @Test("moderation filters actor subjects and muted words")
  func moderationFiltering() {
    let snapshot = WireViewerModerationSnapshot(
      blockedDIDs: ["did:plc:blocked"],
      mutedDIDs: ["did:plc:muted"],
      mutedWords: ["spoiler"],
      fetchedAt: .now
    )
    #expect(!snapshot.allows(
      item: "item", title: "Story", summary: nil,
      representativeURI: "at://did:plc:blocked/app.bsky.feed.post/one"
    ))
    #expect(!snapshot.allows(
      item: "did:plc:muted", title: "Story", summary: nil, representativeURI: nil
    ))
    #expect(!snapshot.allows(
      item: "item", title: "A spoiler appears", summary: nil, representativeURI: nil
    ))
    #expect(snapshot.allows(
      item: "item", title: "A safe story", summary: nil, representativeURI: nil
    ))
  }

  @Test("conditional caching never crosses the anonymous moderation boundary")
  func conditionalCacheIsolation() throws {
    let etag = #""wire-generation-page""#
    let anonymous = try WireDiscoveryRoutes.response(
      ["ok": true], etag: etag, ifNoneMatch: etag, authenticated: false
    )
    #expect(anonymous.status == .notModified)
    #expect(anonymous.headers[.vary] == "Authorization, Accept-Language")

    let authenticated = try WireDiscoveryRoutes.response(
      ["ok": true], etag: etag, ifNoneMatch: etag, authenticated: true
    )
    #expect(authenticated.status == .ok)
    #expect(authenticated.headers[.cacheControl] == "private, max-age=0")
    #expect(authenticated.headers[.vary] == "Authorization, Accept-Language")
  }

  @Test("sparse locales retry against the global simplified fallback corpus")
  func sparseLocaleUsesGlobalFallback() {
    #expect(PostgresWireFeedStore.requiresGlobalFallback(
      requestedLanguage: "en",
      localizedCandidateCount: 0
    ))
    #expect(PostgresWireFeedStore.requiresGlobalFallback(
      requestedLanguage: "en",
      localizedCandidateCount: WireDataPolicy.diverseFirstPageCount - 1
    ))
    #expect(!PostgresWireFeedStore.requiresGlobalFallback(
      requestedLanguage: "en",
      localizedCandidateCount: WireDataPolicy.diverseFirstPageCount
    ))
    #expect(!PostgresWireFeedStore.requiresGlobalFallback(
      requestedLanguage: "und",
      localizedCandidateCount: 0
    ))
  }
}
