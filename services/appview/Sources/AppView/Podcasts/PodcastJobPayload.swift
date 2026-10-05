import ThinAppViewCore

struct PodcastJobPayload: Codable, Sendable {
  let episode: PodcastEpisode
  var show: PodcastShow?
  var clipId: String?
  var startSeconds: Double?
  var endSeconds: Double?
  var title: String?
  var sourceFingerprint: String?
}
