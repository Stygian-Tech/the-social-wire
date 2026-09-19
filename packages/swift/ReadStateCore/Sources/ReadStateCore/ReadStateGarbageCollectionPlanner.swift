import Foundation

/// Pure planning uses only an already verified complete snapshot. The engine
/// separately proves candidate membership at this exact commit before deletion.
public enum ReadStateGarbageCollectionPlanner {
  public static func makeBatch(viewerDid: String, snapshot: ReadStateGarbageCollectionTransport.Snapshot,
    candidates: [ReadStateReference]) throws -> ReadStateGarbageCollectionBatch {
    let record = snapshot.record
    try validate(snapshot, viewerDid: viewerDid)
    guard !candidates.isEmpty, candidates.count <= 100,
      Set(candidates.map(\.uri)).count == candidates.count,
      record.manifest.effectiveRevision < ReadStateValidation.maximumSequence else { throw ReadStateError.invalidRecord }
    let reachable = Set(snapshot.projection.sourceReferences.map(\.uri))
    for candidate in candidates {
      try ReadStateValidation.validate(candidate, viewerDid: viewerDid)
      guard !reachable.contains(candidate.uri) else { throw ReadStateError.invalidReference }
    }
    let current = record.manifest
    let manifest = ReadStateManifest(generation: UUID().uuidString.lowercased(),
      revision: current.effectiveRevision + 1, lastSequence: current.lastSequence,
      stateHead: current.stateHead, devicesHead: current.devicesHead, legacyReceiptsHead: current.legacyReceiptsHead)
    let batch = ReadStateGarbageCollectionBatch(viewerDid: viewerDid, swapCommit: snapshot.repositoryCommitCid,
      previousManifestCid: record.cid, manifest: manifest, deletions: candidates)
    _ = try batch.applyWritesJSON()
    return batch
  }
  static func validate(_ snapshot: ReadStateGarbageCollectionTransport.Snapshot, viewerDid: String) throws {
    try ReadStateValidation.validate(snapshot.record.manifest, viewerDid: viewerDid)
    guard snapshot.viewerDid == viewerDid, !snapshot.repositoryCommitCid.isEmpty,
      snapshot.repositoryCommitCid.utf8.count <= 256, !snapshot.record.cid.isEmpty,
      snapshot.record.manifest.version == 2, snapshot.projection.protocolVersion == 2,
      snapshot.projection.allowsRepacking,
      snapshot.projection.lastSequence == snapshot.record.manifest.lastSequence else { throw ReadStateError.invalidRecord }
    for reference in [snapshot.record.manifest.stateHead, snapshot.record.manifest.devicesHead,
      snapshot.record.manifest.legacyReceiptsHead].compactMap({ $0 }) {
      guard snapshot.projection.sourceReferences.contains(reference) else { throw ReadStateError.incompleteGeneration }
    }
  }
}
