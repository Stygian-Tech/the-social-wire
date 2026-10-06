import Foundation
import Testing
import ThinAppViewCore
@testable import AppView

struct PodcastEmbeddedChapterArtworkTests {
  private actor Source {
    var requests: [(String, Int, String)] = []
    let tag = Data([73, 68, 51, 3, 0, 0, 0, 0, 0, 12] + Array("TIT2".utf8) + [0, 0, 0, 2, 0, 0, 0, 0])
    func fetch(_ url: String, _ maximum: Int, _ range: String) async throws -> Data {
      requests.append((url, maximum, range))
      await Task.yield()
      return Data(tag.prefix(maximum))
    }
    func count() -> Int { requests.count }
    func ranges() -> [String] { requests.map(\.2) }
  }
  private func episode(id: String = "episode", visibility: String = "public") throws -> PodcastEpisode {
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "showId": "show", "title": "Episode",
      "publishedAt": "2026-10-06T00:00:00Z", "audioUrl": "https://publisher.example/\(id).mp3",
      "transcripts": [], "visibility": visibility] as [String: Any])
    return try JSONDecoder().decode(PodcastEpisode.self, from: data)
  }
  @Test func cachesOnlyBoundedTagPrefixesAndIsolatesPrivateOwners() async throws {
    let cache = PodcastEmbeddedChapterArtwork()
    let source = Source()
    let fetch: @Sendable (String, Int, String) async throws -> Data = { try await source.fetch($0, $1, $2) }
    let item = try episode(visibility: "private")
    _ = try await cache.artwork(episode: item, viewer: "alice", fetch: fetch)
    _ = try await cache.artwork(episode: item, viewer: "alice", fetch: fetch)
    #expect(await source.count() == 2)
    #expect(await source.ranges() == ["bytes=0-9", "bytes=0-21"])
    _ = try await cache.artwork(episode: item, viewer: "bob", fetch: fetch)
    #expect(await source.count() == 4)
    await #expect(throws: (any Error).self) {
      _ = try await cache.artwork(episode: item, viewer: nil, fetch: fetch)
    }
    #expect(await source.count() == 4)
  }
  @Test func coalescesConcurrentRequestsForOneEpisode() async throws {
    let cache = PodcastEmbeddedChapterArtwork()
    let source = Source()
    let item = try episode()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask {
          _ = try await cache.artwork(episode: item, viewer: "alice") { try await source.fetch($0, $1, $2) }
        }
      }
      try await group.waitForAll()
    }
    #expect(await source.count() == 2)
  }
  @Test func evictsOldestEntriesAtEightEpisodes() async throws {
    let cache = PodcastEmbeddedChapterArtwork()
    let source = Source()
    for index in 0..<9 {
      _ = try await cache.artwork(episode: try episode(id: "episode\(index)"), viewer: nil) { try await source.fetch($0, $1, $2) }
    }
    #expect(await source.count() == 18)
    _ = try await cache.artwork(episode: try episode(id: "episode0"), viewer: nil) { try await source.fetch($0, $1, $2) }
    #expect(await source.count() == 20)
  }
  @Test func enrichesOnlyMissingMatchingImagesWithEncodedRoutes() throws {
    var item = try episode(id: "episode?token=not-a-query&part=1")
    item.chapters = [PodcastChapter(startSeconds: 0, title: "Intro"),
      PodcastChapter(startSeconds: 30, title: "Publisher", artworkUrl: "https://publisher.example/chapter.jpg"),
      PodcastChapter(startSeconds: 60, title: "Missing")]
    let images = [0.1, 30.0, 90.0].map { PodcastID3ChapterArtwork(startSeconds: $0, data: Data(), mimeType: "image/png") }
    let result = PodcastEmbeddedChapterArtwork.enrich(episode: item, images: images)
    let route = try #require(result.chapters[0].artworkUrl)
    let components = try #require(URLComponents(string: route))
    #expect(components.path == "/v1/podcasts/image")
    #expect(components.queryItems?.first(where: { $0.name == "episodeId" })?.value == item.id)
    #expect(components.queryItems?.first(where: { $0.name == "index" })?.value == "0")
    #expect(result.chapters[1].artworkUrl == item.chapters[1].artworkUrl)
    #expect(result.chapters[2].artworkUrl == nil)
  }
}
