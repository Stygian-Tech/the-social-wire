import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

extension PodcastService {
  func resolvePrivate(viewer: String, raw: String, existingOnly: Bool = false) async throws -> PodcastResolveResponse {
    _ = try await store.requirePrivateStorage()
    let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard PodcastPrivateCatalog.isAllowedURL(url) else {
      throw HTTPError(.badRequest, message: "Private Feeds Require HTTPS Without URL Userinfo")
    }
    do {
      let body = try await PublicMediaFetcher.fetch(url: url, httpClient: http,
        maximumBytes: 32 * 1024 * 1024, validateURL: PodcastPrivateCatalog.isAllowedURL)
      let parsed = try PodcastRSSParser(feedURL: url).parse(body)
      guard !parsed.episodes.isEmpty else { throw PodcastParseError.invalidMedia }
      let scoped = PodcastPrivateCatalog.scope(viewer: viewer, feedURL: url, show: parsed.show, episodes: parsed.episodes)
      try await store.savePrivateCatalog(viewer: viewer, feedURL: url, show: scoped.show, episodes: scoped.episodes, existingOnly: existingOnly)
      return PodcastResolveResponse(show: PodcastPrivateCatalog.visible(scoped.show), episodes: scoped.episodes.map(PodcastPrivateCatalog.visible))
    } catch PodcastStoreError.notFound {
      throw HTTPError(.notFound, message: "Private Podcast Subscription Not Found")
    } catch PodcastStoreError.privateStorageUnavailable {
      throw PodcastStoreError.privateStorageUnavailable
    } catch {
      // Never propagate a URL/token-bearing upstream or database diagnostic.
      throw HTTPError(.badRequest, message: "Private Podcast Feed Could Not Be Loaded")
    }
  }

  func refreshPrivate(viewer: String, showID: String) async throws -> PodcastResolveResponse {
    guard let feed = try await store.privateFeed(viewer: viewer, id: showID) else { throw HTTPError(.notFound) }
    return try await resolvePrivate(viewer: viewer, raw: feed.url, existingOnly: true)
  }

  func privateShows(viewer: String) async throws -> [PodcastShow] {
    let feeds = try await store.stalePrivateFeeds(viewer: viewer)
    await withTaskGroup(of: Void.self) { group in
      for feed in feeds {
        group.addTask { _ = try? await self.resolvePrivate(viewer: viewer, raw: feed, existingOnly: true) }
      }
    }
    return try await store.privateShows(viewer: viewer).map(PodcastPrivateCatalog.visible)
  }

  func episode(id: String, viewer: String) async throws -> PodcastEpisode? {
    if PodcastPrivateCatalog.isPrivateID(id) { return try await store.privateEpisode(viewer: viewer, id: id) }
    return try await store.episode(id: id)
  }

  func visibleEpisode(_ episode: PodcastEpisode) -> PodcastEpisode {
    episode.visibility == "private" ? PodcastPrivateCatalog.visible(episode) : episode
  }
}
