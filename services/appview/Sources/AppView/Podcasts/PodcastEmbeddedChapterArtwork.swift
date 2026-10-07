import AsyncHTTPClient
import Foundation
import GatewayCore
import ThinAppViewCore

/// Small, owner-scoped cache of bounded MP3 metadata prefixes. Audio is never downloaded in full.
actor PodcastEmbeddedChapterArtwork {
  private enum Failure: Error { case unavailable }
  static let shared = PodcastEmbeddedChapterArtwork()
  private struct Key: Hashable {
    let scope: String
    let url: String
  }
  private struct Entry {
    let expires: Date
    let images: [PodcastID3ChapterArtwork]
  }
  private var cached: [Key: Entry] = [:]
  private var pending: [Key: Task<[PodcastID3ChapterArtwork], Error>] = [:]
  private let now: @Sendable () -> Date

  init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

  func artwork(episode: PodcastEpisode, viewer: String?, http: HTTPClient) async throws -> [PodcastID3ChapterArtwork] {
    try await artwork(episode: episode, viewer: viewer) { url, maximumBytes, range in
      try await PublicMediaFetcher.fetch(url: url, httpClient: http, maximumBytes: maximumBytes,
        timeout: .seconds(8), requestHeaders: [("Range", range), ("User-Agent", "TheSocialWirePodcastMetadata/1.0")], allowPartialResponse: true, maximumRedirects: 10)
    }
  }

  nonisolated static func enrich(episode: PodcastEpisode, images: [PodcastID3ChapterArtwork]) -> PodcastEpisode {
    var output = episode
    for index in output.chapters.indices where output.chapters[index].artworkUrl == nil {
      guard images.contains(where: { abs($0.startSeconds - output.chapters[index].startSeconds) < 0.5 }) else { continue }
      var components = URLComponents()
      components.path = "/v1/podcasts/image"
      components.queryItems = [URLQueryItem(name: "episodeId", value: episode.id),
        URLQueryItem(name: "kind", value: "chapter"), URLQueryItem(name: "index", value: String(index))]
      output.chapters[index].artworkUrl = components.string
    }
    return output
  }

  func artwork(episode: PodcastEpisode, viewer: String?,
    fetch: @escaping @Sendable (String, Int, String) async throws -> Data) async throws -> [PodcastID3ChapterArtwork] {
    let scope: String
    if episode.visibility == "private" {
      guard let viewer, !viewer.isEmpty else { throw Failure.unavailable }
      scope = "private:\(viewer)"
    } else { scope = "public" }
    let key = Key(scope: scope, url: episode.audioUrl)
    let time = now()
    cached = cached.filter { $0.value.expires > time }
    if let hit = cached[key] { return hit.images }
    if let task = pending[key] { return try await task.value }
    // Bound both cached entries and concurrent prefixes to eight episodes in this process.
    if cached.count + pending.count >= 8, let oldest = cached.min(by: { $0.value.expires < $1.value.expires }) {
      cached.removeValue(forKey: oldest.key)
    }
    guard cached.count + pending.count < 8 else { throw Failure.unavailable }
    let task = Task<[PodcastID3ChapterArtwork], Error> {
      let header = try await fetch(episode.audioUrl, 10, "bytes=0-9")
      guard let size = PodcastID3ChapterArtworkParser.tagByteCount(header: header) else { return [] }
      let tag = try await fetch(episode.audioUrl, size, "bytes=0-\(size - 1)")
      return PodcastID3ChapterArtworkParser.parse(tag)
    }
    pending[key] = task
    do {
      let images = try await task.value
      pending.removeValue(forKey: key)
      cached[key] = Entry(expires: now().addingTimeInterval(300), images: images)
      return images
    } catch {
      pending.removeValue(forKey: key)
      throw error
    }
  }
}
