protocol CircleProfileReading: Sendable {
  func profiles(actorDIDs: Set<String>) async throws -> [String: CirclePublicIdentity]
}
