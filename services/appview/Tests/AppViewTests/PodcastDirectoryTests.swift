import AsyncHTTPClient
import Foundation
import Testing
import ThinAppViewCore
@testable import AppView

struct PodcastDirectoryTests {
  private let fixture = #"{"resultCount":1,"results":[{"kind":"podcast","trackId":123,"collectionName":"Public Show","feedUrl":"https://example.com/rss.xml","artworkUrl600":"https://example.com/art.jpg"}]}"#

  @Test func acceptsExplicitPublicTopicsAndRejectsURLCredentialInputs() throws {
    for query in ["Café Science", "99% Invisible", "A + B", "東京", "password managers"] {
      #expect(try PodcastDirectoryQuery.validate(PodcastSearchRequest(query: query, scope: "directory")) == query)
    }
    for query in ["https://example.com/rss?token=secret", "http:example.com", "example.com/feed", "www.example.com", "user@example.com", "token=secret", "api_key: secret", "Bearer credential", "https%3A%2F%2Fexample.com", "https%253A%252F%252Fexample.com", "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJwcml2YXRlIn0.c2VjcmV0c2lnbmF0dXJl", String(repeating: "a", count: 48)] {
      #expect(throws: PodcastDirectoryError.invalidQuery) { try PodcastDirectoryQuery.validate(PodcastSearchRequest(query: query, scope: "directory")) }
    }
    #expect(throws: PodcastDirectoryError.invalidRequest) { try PodcastDirectoryQuery.validate(PodcastSearchRequest(query: "public", scope: "directory", cursor: "cursor")) }
    #expect(throws: PodcastDirectoryError.invalidRequest) { try PodcastDirectoryQuery.validate(PodcastSearchRequest(query: "public", scope: "library")) }
  }

  @Test func buildsOnlyFixedProviderURLAndPreservesLiteralPlus() throws {
    let url = try PodcastDirectoryFetcher.requestURL("Café A + B")
    #expect(URLComponents(string: url)?.host == "api.podcastindex.org")
    #expect(URLComponents(string: url)?.path == "/search")
    #expect(url.contains("%2B") && url.contains("%20"))
    let query = try #require(URLComponents(string: url)?.percentEncodedQuery)
    #expect(query.replacingOccurrences(of: "+", with: " ").removingPercentEncoding == "term=Café A + B")
  }

  @Test func parsesOnlyPublicPodcastCandidatesAndBoundsDuplicates() throws {
    let good = try PodcastDirectoryParser.parse(Data(fixture.utf8))
    #expect(good.count == 1 && good[0].provider == "podcastindex" && good[0].id == "123")
    let rows: [[String: Any]] = [
      ["kind":"podcast", "trackId":1, "collectionName":"Allowed", "feedUrl":"https://example.com/?feed=rss2", "artworkUrl600":"javascript:bad", "artworkUrl100":"https://example.com/good.jpg"],
      ["kind":"podcast", "trackId":2, "collectionName":"Duplicate", "feedUrl":"https://example.com/?feed=rss2"],
      ["kind":"podcast", "trackId":3, "collectionName":"Token", "feedUrl":"https://example.com/?token=secret"],
      ["kind":"podcast", "trackId":4, "collectionName":"HTTP", "feedUrl":"http://example.com/rss"],
      ["kind":"podcast", "trackId":5, "collectionName":"Local", "feedUrl":"https://127.0.0.1/rss"],
      ["kind":"podcast", "trackId":6, "collectionName":"Private", "feedUrl":"https://worker.railway.internal/rss"],
      ["kind":"podcast", "trackId":7, "collectionName":"Credentials", "feedUrl":"https://user:secret@example.com/rss"],
      ["kind":"movie", "trackId":8, "collectionName":"Video", "feedUrl":"https://example.com/video"],
    ]
    let parsed = try PodcastDirectoryParser.parse(JSONSerialization.data(withJSONObject: ["resultCount":rows.count,"results":rows]))
    #expect(parsed.count == 1 && parsed[0].artworkUrl == "https://example.com/good.jpg")
    for bad in ["{}", "[]", "not-json", #"{"resultCount":1,"results":[]}"#, #"{"resultCount":0,"results":{}}"#] {
      #expect(throws: PodcastDirectoryError.unavailable) { try PodcastDirectoryParser.parse(Data(bad.utf8)) }
    }
    let many = (0..<80).map { ["kind":"podcast", "trackId":$0+1, "collectionName":"Public", "feedUrl":"https://example.com/rss/\($0)"] as [String:Any] }
    #expect(try PodcastDirectoryParser.parse(JSONSerialization.data(withJSONObject: ["resultCount":many.count,"results":many])).count == 50)
  }

  @Test func cachesPublicResultsAndRateLimitsOnlyMisses() async throws {
    let search = PodcastDirectorySearch(maximumRequests: 1)
    let calls = Calls()
    let data = Data(fixture.utf8)
    let fetch: @Sendable (String) async throws -> Data = { _ in await calls.increment(); return data }
    let first = try await search.search(PodcastSearchRequest(query: "Public", scope: "directory", limit: 50), fetch: fetch)
    let cached = try await search.search(PodcastSearchRequest(query: "PUBLIC", scope: "directory", limit: 1), fetch: fetch)
    #expect(first.candidates.count == 1 && cached.candidates == first.candidates)
    #expect(first.directoryLimit == 50 && !first.hasMore && first.cursor == nil)
    #expect(await calls.count == 1)
    await #expect(throws: PodcastDirectoryError.busy) { try await search.search(PodcastSearchRequest(query: "Another", scope: "directory"), fetch: fetch) }
  }

  @Test func upgradesHTTPArtworkWithoutRelaxingPublicURLValidation() throws {
    let artworkURLs = [
      "http://example.com/art.jpg?size=600",
      "http://127.0.0.1/art.jpg",
      "http://worker.railway.internal/art.jpg",
      "http://localhost/art.jpg",
      "http://user:secret@example.com/art.jpg",
      "http://example.com/art.jpg#fragment",
    ]
    var rows = artworkURLs.enumerated().map { index, artwork in
      ["kind": "podcast", "trackId": index + 1, "collectionName": "Public",
       "feedUrl": "https://example.com/rss/\(index)", "artworkUrl600": artwork] as [String: Any]
    }
    rows.append(["kind": "podcast", "trackId": 100, "collectionName": "HTTP Feed",
      "feedUrl": "http://example.com/rss", "artworkUrl600": "http://example.com/art.jpg"])
    let parsed = try PodcastDirectoryParser.parse(JSONSerialization.data(withJSONObject: ["resultCount": rows.count, "results": rows]))
    #expect(parsed.count == artworkURLs.count)
    #expect(parsed[0].artworkUrl == "https://example.com/art.jpg?size=600")
    #expect(parsed.dropFirst().allSatisfy { $0.artworkUrl == nil })
  }

  @Test func prefersExplicitHTTPSArtworkOverUpgradingLargerHTTPArtwork() throws {
    let row: [String: Any] = ["kind": "podcast", "trackId": 1, "collectionName": "Public",
      "feedUrl": "https://example.com/rss", "artworkUrl600": "http://example.com/large.jpg",
      "artworkUrl100": "https://example.com/small.jpg", "artworkUrl60": "https://example.com/tiny.jpg"]
    let parsed = try PodcastDirectoryParser.parse(JSONSerialization.data(withJSONObject: ["resultCount": 1, "results": [row]]))
    #expect(parsed.first?.artworkUrl == "https://example.com/small.jpg")
  }

  @Test func inputValidationPrecedesProviderAndFailuresRemainGeneric() async throws {
    let search = PodcastDirectorySearch()
    let calls = Calls()
    let fetch: @Sendable (String) async throws -> Data = { _ in await calls.increment(); throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey:URL(string: "https://provider.example/?secret=private")!]) }
    await #expect(throws: PodcastDirectoryError.invalidQuery) { try await search.search(PodcastSearchRequest(query:"token=private",scope:"directory"),fetch:fetch) }
    await #expect(throws: PodcastDirectoryError.invalidRequest) { try await search.search(PodcastSearchRequest(query:"Private",scope:"library"),fetch:fetch) }
    #expect(await calls.count == 0)
    await #expect(throws: PodcastDirectoryError.unavailable) { try await search.search(PodcastSearchRequest(query:"Public",scope:"directory"),fetch:fetch) }
    #expect(await calls.count == 1)
  }

  @Test func deduplicatesConcurrentRequestsAndBoundsOtherQueries() async throws {
    let search = PodcastDirectorySearch(maximumConcurrent: 1)
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let data = Data(fixture.utf8)
    let calls = Calls()
    let fetch: @Sendable (String) async throws -> Data = { _ in
      await calls.increment(); started.continuation.yield(())
      for await _ in release.stream { break }
      return data
    }
    let first = Task { try await search.search(PodcastSearchRequest(query:"Public",scope:"directory"),fetch:fetch) }
    for await _ in started.stream { break }
    let second = Task { try await search.search(PodcastSearchRequest(query:"Public",scope:"directory"),fetch:fetch) }
    await #expect(throws: PodcastDirectoryError.busy) { try await search.search(PodcastSearchRequest(query:"Other",scope:"directory"),fetch:fetch) }
    release.continuation.yield(())
    #expect(try await first.value.candidates == second.value.candidates)
    #expect(await calls.count == 1)
    started.continuation.finish(); release.continuation.finish()
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PODCAST_INDEX_LIVE_TEST"] == "true"))
  func liveKeylessProviderContract() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      let body = try await PodcastDirectoryFetcher.fetch("batman", http: client)
      let candidates = try PodcastDirectoryParser.parse(body)
      #expect(!candidates.isEmpty && candidates.count <= 50)
      #expect(candidates.allSatisfy { $0.provider == "podcastindex" && PodcastRSSURL.isAllowed($0.feedUrl) })
    } catch { try? await client.shutdown(); throw error }
    try await client.shutdown()
  }
  private actor Calls {
    var count = 0
    func increment() { count += 1 }
  }
}
