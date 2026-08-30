protocol CirclePublicFollowReading: Sendable {
  /// Expands direct actors through the public graph without accepting an OAuth token, DPoP proof,
  /// or authenticated client. Concrete readers must use the unauthenticated public graph surface.
  func follows(of actorDIDs: Set<String>) async throws -> [CircleFollowList]
}
