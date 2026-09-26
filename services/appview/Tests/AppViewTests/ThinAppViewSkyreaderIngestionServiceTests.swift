import GatewayCore
import Logging
import Testing
@testable import AppView

@Suite("Selected Skyreader feed warming")
struct ThinAppViewSkyreaderIngestionServiceTests {
  @Test("selected warming normalizes and deduplicates without repository enumeration")
  func selectedFeedsOnly() async throws {
    let recorder = SkyreaderWarmingRecorder()
    let service = ThinAppViewSkyreaderIngestionService(
      viewerFeedUrls: { _ in
        await recorder.recordLookup()
        throw FixtureFailure.repositoryUnavailable
      },
      ingestFeed: { url in
        await recorder.recordFeed(url)
        return 3
      },
      logger: Logger(label: "skyreader-selected.tests")
    )
    let count = try await service.ingestSelectedFeeds(feedUrls: [
      " https://selected.example/feed#fragment ",
      "http://selected.example/feed",
      "", "   ",
      "other.example/rss/",
      "https://other.example/rss",
    ])
    #expect(count == 6)
    #expect(await recorder.lookupCount == 0)
    #expect(await recorder.feeds == ["https://selected.example/feed", "https://other.example/rss"])
    #expect(try await service.ingestSelectedFeeds(feedUrls: []) == 0)
    #expect(await recorder.lookupCount == 0)
  }

  @Test("full viewer warming still enumerates every feed and preserves priority order")
  func fullViewerWarmingPreserved() async throws {
    let recorder = SkyreaderWarmingRecorder()
    let feeds = (0..<51).map { "https://feed\($0).example/rss" }
    let service = ThinAppViewSkyreaderIngestionService(
      viewerFeedUrls: { _ in
        await recorder.recordLookup()
        return feeds + [feeds[0]]
      },
      ingestFeed: { url in
        await recorder.recordFeed(url)
        return 1
      },
      logger: Logger(label: "skyreader-background.tests")
    )
    let auth = AuthContext(
      did: "did:plc:skyreader-test-viewer",
      authorizationForwardingValue: "DPoP fixture",
      dpopProof: "fixture"
    )
    let count = try await service.ingestViewerSubscriptions(
      auth: auth, priorityFeedUrls: [feeds[50], feeds[50]]
    )
    #expect(count == 51)
    #expect(await recorder.lookupCount == 1)
    #expect(await recorder.feeds == [feeds[50]] + Array(feeds.prefix(50)))
  }

  @Test("cancellation cannot continue warming after a fetch returns normally")
  func cancellationStopsRemainingFeeds() async throws {
    let recorder = SkyreaderWarmingRecorder()
    let service = ThinAppViewSkyreaderIngestionService(
      viewerFeedUrls: { _ in
        await recorder.recordLookup()
        return []
      },
      ingestFeed: { url in
        await recorder.recordFeed(url)
        // Model a fetcher that observes cancellation but returns zero instead of throwing.
        withUnsafeCurrentTask { $0?.cancel() }
        return 0
      },
      logger: Logger(label: "skyreader-cancellation.tests")
    )
    let task = Task {
      try await service.ingestSelectedFeeds(feedUrls: ["one.example/rss", "two.example/rss"])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await recorder.feeds == ["https://one.example/rss"])
    #expect(await recorder.lookupCount == 0)
  }

  @Test("fetch failure propagates without broadening to other feeds and a later selection can retry")
  func failureDoesNotBroadenWarming() async throws {
    let recorder = SkyreaderWarmingRecorder()
    let service = ThinAppViewSkyreaderIngestionService(
      viewerFeedUrls: { _ in
        await recorder.recordLookup()
        return []
      },
      ingestFeed: { url in
        await recorder.recordFeed(url)
        if await recorder.feeds.count == 1 { throw FixtureFailure.fetchUnavailable }
        return 4
      },
      logger: Logger(label: "skyreader-failure.tests")
    )
    await #expect(throws: FixtureFailure.fetchUnavailable) {
      try await service.ingestSelectedFeeds(feedUrls: ["one.example/rss", "two.example/rss"])
    }
    #expect(await recorder.feeds == ["https://one.example/rss"])
    #expect(try await service.ingestSelectedFeeds(feedUrls: ["one.example/rss"]) == 4)
    #expect(await recorder.lookupCount == 0)
  }

  private enum FixtureFailure: Error, Equatable {
    case repositoryUnavailable
    case fetchUnavailable
  }
}
