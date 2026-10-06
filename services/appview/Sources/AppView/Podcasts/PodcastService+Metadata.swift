import Foundation
import GatewayCore
import ThinAppViewCore

extension PodcastService {
  /// Resolve only the requested page, with at most eight bounded source requests in flight.
  func enrich(_ episodes: [PodcastEpisode], viewer: String?, persist: Bool = true, embeddedArtwork: Bool = false) async -> [PodcastEpisode] {
    var output = episodes
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    for offset in stride(from: 0, to: min(episodes.count, 100), by: 8) {
      guard ContinuousClock.now < deadline else { break }
      await withTaskGroup(of: (Int, PodcastEpisode).self) { group in
        for index in offset..<min(offset + 8, episodes.count, 100) {
          group.addTask {
            var episode = episodes[index]
            let original = episode
            if episode.chapters.isEmpty, let url = episode.chapterSourceUrl,
              let data = try? await PublicMediaFetcher.fetch(url: url, httpClient: self.http, maximumBytes: 2 * 1024 * 1024, timeout: min(.seconds(3), ContinuousClock.now.duration(to: deadline))) {
              episode.chapters = PodcastChapterParser.parse(data, duration: episode.durationSeconds)
            }
            if episode.showArtworkUrl == nil {
              let show = episode.visibility == "private"
                ? (try? await self.store.privateShow(viewer: viewer ?? "", id: episode.showId))
                : (try? await self.store.show(id: episode.showId))
              episode.showArtworkUrl = show?.artworkUrl
            }
            // Fetch embedded images only for the selected episode, never every library row.
            if embeddedArtwork, !episode.chapters.isEmpty,
              episode.chapters.contains(where: { $0.artworkUrl == nil }),
              let images = try? await PodcastEmbeddedChapterArtwork.shared.artwork(episode: episode, viewer: viewer, http: self.http) {
              episode = PodcastEmbeddedChapterArtwork.enrich(episode: episode, images: images)
            }
            if persist, episode != original { try? await self.store.updateMetadata(episode: episode, viewer: viewer) }
            return (index, episode)
          }
        }
        for await (index, episode) in group { output[index] = episode }
      }
    }
    return output
  }
}
