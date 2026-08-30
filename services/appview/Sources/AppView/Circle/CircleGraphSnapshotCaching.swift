protocol CircleGraphSnapshotCaching: Sendable {
  func load(
    viewerDID: String,
    excludedDIDs: Set<String>
  ) async throws -> CircleGraphSnapshot?

  func store(
    _ snapshot: CircleGraphSnapshot,
    excludedDIDs: Set<String>
  ) async throws
}
