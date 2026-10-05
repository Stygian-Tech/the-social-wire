public struct PodcastStateSnapshot: Codable, Sendable {
  public var revision: Int64
  public var state: PodcastListenerState
  public init(revision: Int64, state: PodcastListenerState) {
    self.revision = revision
    self.state = state
  }
}
