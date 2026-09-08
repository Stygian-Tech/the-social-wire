import Foundation
import Logging
import ReadStateCore
import Testing
import ThinAppViewCore
@testable import AppView

@Test func verifiedConfirmationInvalidatesOnlyTheConfirmedViewersProjections() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("pds-confirm-\(UUID().uuidString).sqlite").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let cache = try SQLiteAppViewProjectionCacheStore(path: path, logger: Logger(label: "pds-confirm-cache.test"))
  let viewer = "did:plc:confirmed"
  let other = "did:plc:other"
  let publication = "publication"
  for did in [viewer, other] {
    try await cache.storeSidebarProjectionJSON(viewerDid: did, jsonBody: "{}", expiresAt: Date().addingTimeInterval(300))
    try await cache.storeUnreadCounts(viewerDid: did, counts: [publication: 7], expiresAt: Date().addingTimeInterval(300))
    try await cache.storeFirstPageJSON(viewerDid: did, publicationId: publication, jsonBody: "{}", expiresAt: Date().addingTimeInterval(300))
  }
  let store = ConfirmationStore()
  let manifest = ReadStateManifest(generation: "empty", lastSequence: 0, head: nil)
  let projection = try ReadStateProjection(operations: [], lastSequence: 0)
  // Failed parity must preserve every cache and the old authority.
  await #expect(throws: PDSReadStateStorageError.parityMismatch) {
    try await PDSReadStateService.activateVerifiedGeneration(store: store, projectionCache: cache,
      viewerDid: viewer, manifest: manifest, manifestCid: "verified", projection: projection, expectedLegacyRevision: 1)
  }
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: viewer) != nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: viewer)?.value[publication] == 7)
  #expect(try await cache.firstPageCacheEntry(viewerDid: viewer, publicationId: publication) != nil)
  await store.allowActivation()
  let status = try await PDSReadStateService.activateVerifiedGeneration(store: store, projectionCache: cache,
    viewerDid: viewer, manifest: manifest, manifestCid: "verified", projection: projection, expectedLegacyRevision: 1)
  #expect(status.authority == .pds)
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: viewer) == nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: viewer) == nil)
  #expect(try await cache.firstPageCacheEntry(viewerDid: viewer, publicationId: publication) == nil)
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: other) != nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: other)?.value[publication] == 7)
  #expect(try await cache.firstPageCacheEntry(viewerDid: other, publicationId: publication) != nil)
}

private actor ConfirmationStore: PDSReadStateStoring {
  private var allowed = false
  func allowActivation() { allowed = true }
  func pdsReadStateStatus(viewerDid: String) -> PDSReadStateStatus {
    .init(authority: .appview, migrationState: .notStarted, legacyRevision: 1)
  }
  func activatePDSReadState(viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
    projection: ReadStateProjection, expectedLegacyRevision: Int64?) throws -> PDSReadStateStatus {
    guard allowed else { throw PDSReadStateStorageError.parityMismatch }
    return .init(authority: .pds, migrationState: .verified, legacyRevision: 1, manifest: manifest, manifestCid: manifestCid)
  }
  func exportPDSReadStatePage(viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int) throws -> PDSReadStateExportPage { throw PDSReadStateStorageError.alreadyMigrated }
  func preparePDSReadStateBoundaries(viewerDid: String, scopes: [PublicationUnreadScope], at: Date) -> [ReadStateBoundary] { [] }
  func previewPDSReadStateBoundaries(viewerDid: String, boundaries: [ReadStateBoundary], subjectUris: [String]) -> [String] { [] }
}
