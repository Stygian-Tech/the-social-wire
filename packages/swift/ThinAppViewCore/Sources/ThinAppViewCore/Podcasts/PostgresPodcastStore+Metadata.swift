import Foundation
import PostgresNIO

extension PostgresPodcastStore {
  public func updateMetadata(episode: PodcastEpisode, viewer: String?) async throws {
    if episode.visibility == "private" {
      guard let viewer else { throw PodcastStoreError.invalidRequest }
      let storage = try requirePrivateStorage()
      let rows = try await pool.query("SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=\(episode.id)", logger: logger)
      for try await row in rows {
        let ciphertext = try row.decode(String.self)
        var current = try decode(storage.open(ciphertext, viewer: viewer, entity: "episode", id: episode.id), PodcastEpisode.self)
        guard current.id == episode.id, current.showId == episode.showId,
          current.audioUrl == episode.audioUrl, current.chapterSourceUrl == episode.chapterSourceUrl
        else { return }
        // Merge onto the latest catalog row; a refresh after this read wins the ciphertext CAS.
        current.chapters = episode.chapters
        current.showArtworkUrl = episode.showArtworkUrl
        let encrypted = try storage.seal(json(current), viewer: viewer, entity: "episode", id: episode.id)
        _ = try await pool.query("UPDATE podcast_private_episodes SET episode_data=\(encrypted) WHERE viewer_did=\(viewer) AND id=\(episode.id) AND episode_data=\(ciphertext)", logger: logger)
      }
    } else {
      guard !PodcastPrivateCatalog.isPrivateID(episode.id) else { throw PodcastStoreError.invalidRequest }
      let fields = try JSONSerialization.data(withJSONObject: ["chapters": JSONSerialization.jsonObject(with: JSONEncoder().encode(episode.chapters)), "showArtworkUrl": episode.showArtworkUrl as Any? ?? NSNull()])
      let value = String(decoding: fields, as: UTF8.self)
      _ = try await pool.query("UPDATE podcast_episodes SET episode_json=episode_json || \(value)::jsonb WHERE id=\(episode.id) AND show_id=\(episode.showId) AND episode_json->>'audioUrl'=\(episode.audioUrl) AND episode_json->>'chapterSourceUrl' IS NOT DISTINCT FROM \(episode.chapterSourceUrl)", logger: logger)
    }
  }
}
