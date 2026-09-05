import Foundation

protocol CirclePrivateStateStoring: CircleGraphSnapshotCaching {
  func hiddenStoryIDs(viewerDID: String) async throws -> Set<String>
  func setHidden(viewerDID: String, storyID: String, hidden: Bool, now: Date) async throws
  func cachedEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    hiddenStoryIDs: Set<String>,
    now: Date
  ) async throws -> Data?
  func storeEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    hiddenStoryIDs: Set<String>,
    expiresAt: Date,
    payload: Data
  ) async throws
  func purge(viewerDID: String) async throws
}
