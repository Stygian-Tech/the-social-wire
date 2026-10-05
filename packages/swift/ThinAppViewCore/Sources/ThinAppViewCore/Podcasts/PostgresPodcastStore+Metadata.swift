import Foundation
import PostgresNIO

extension PostgresPodcastStore {
  public func updateMetadata(episode: PodcastEpisode, viewer: String?) async throws {
    if episode.visibility == "private" {
      guard let viewer else { throw PodcastStoreError.invalidRequest }
      let encrypted = try requirePrivateStorage().seal(json(episode), viewer: viewer, entity: "episode", id: episode.id)
      _ = try await pool.query("UPDATE podcast_private_episodes SET episode_data=\(encrypted) WHERE viewer_did=\(viewer) AND id=\(episode.id)", logger: logger)
    } else {
      guard !PodcastPrivateCatalog.isPrivateID(episode.id) else { throw PodcastStoreError.invalidRequest }
      let fields = try JSONSerialization.data(withJSONObject: ["chapters": JSONSerialization.jsonObject(with: JSONEncoder().encode(episode.chapters)), "showArtworkUrl": episode.showArtworkUrl as Any? ?? NSNull()])
      let value = String(decoding: fields, as: UTF8.self)
      _ = try await pool.query("UPDATE podcast_episodes SET episode_json=episode_json || \(value)::jsonb WHERE id=\(episode.id)", logger: logger)
    }
  }
}
