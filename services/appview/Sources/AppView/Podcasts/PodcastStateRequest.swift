import ThinAppViewCore

struct PodcastStateRequest: Codable, Sendable {
  let expectedRevision: Int64
  var state: PodcastListenerState
}
