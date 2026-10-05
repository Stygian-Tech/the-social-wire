struct PodcastClipRequest: Codable, Sendable {
  let episodeId: String
  let startSeconds: Double
  let endSeconds: Double
  let title: String?
  let includeCaptions: Bool?
}
