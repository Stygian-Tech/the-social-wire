import Foundation

protocol CircleDisposableCaching: CircleGraphSnapshotCaching {
  func cachedEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, now: Date
  ) async -> Data?
  func storeEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, expiresAt: Date, payload: Data
  ) async
  func invalidateEditions(viewerDID: String) async
  func purge(viewerDID: String) async throws
}
