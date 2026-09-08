import Foundation
import ReadStateCore

/// Only complete, CID-verified manifests may replace an already active projection.
struct PDSReadStateProjector: Sendable {
  typealias FetchRecord = @Sendable (_ viewerDid: String, _ collection: String, _ key: String, _ cid: String?) async throws -> PDSReadStateFetchedRecord
  let store: any PDSReadStateStoring
  let fetchRecord: FetchRecord
  let cache: ReadStateVerifiedChunkCache

  init(store: any PDSReadStateStoring, fetchRecord: @escaping FetchRecord,
       cache: ReadStateVerifiedChunkCache = ReadStateVerifiedChunkCache()) {
    self.store = store
    self.fetchRecord = fetchRecord
    self.cache = cache
  }

  func reconcile(viewerDid: String, rebuildEvicted: Bool = true) async throws -> Bool {
    let status = try await store.pdsReadStateStatus(viewerDid: viewerDid)
    guard status.authority == .pds, status.projectionReady || rebuildEvicted else { return false }
    let record = try await fetchRecord(viewerDid, ReadStateManifest.collection, "self", nil)
    let manifest: ReadStateManifest = try record.decode(viewerDid: viewerDid,
      collection: ReadStateManifest.collection, key: "self")
    let projection = try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewerDid) { reference in
      try ReadStateValidation.validate(reference, viewerDid: viewerDid)
      if let cached = await cache.value(for: reference) { return cached }
      let key = String(reference.uri.split(separator: "/").last ?? "")
      let record = try await fetchRecord(viewerDid, ReadStateChunk.collection, key, reference.cid)
      guard record.cid == reference.cid else { throw ReadStateError.invalidReference }
      let chunk: ReadStateChunk = try record.decode(viewerDid: viewerDid, collection: ReadStateChunk.collection, key: key)
      try await cache.insertVerified(chunk, for: reference)
      return chunk
    }
    let current = try await fetchRecord(viewerDid, ReadStateManifest.collection, "self", nil)
    guard current.cid == record.cid else { throw PDSReadStateStorageError.staleGeneration }
    // Verify this response too; a claimed CID without matching content is not proof.
    let _: ReadStateManifest = try current.decode(viewerDid: viewerDid, collection: ReadStateManifest.collection, key: "self")
    _ = try await store.activatePDSReadState(viewerDid: viewerDid, manifest: manifest,
      manifestCid: record.cid, projection: projection, expectedLegacyRevision: nil)
    return true
  }
}
