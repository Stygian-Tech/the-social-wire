protocol CircleViewerFollowReading: Sendable {
  /// Reads the viewer's own `app.bsky.graph.follow` records from their PDS.
  func follows(viewerDID: String) async throws -> CircleFollowList
}
