import ReadStateCore

public enum PDSReadStateManifestTransition {
  public static func validate(previous: ReadStateManifest, previousCID: String,
                              candidate: ReadStateManifest, candidateCID: String) throws {
    if previousCID == candidateCID {
      guard previous == candidate else { throw PDSReadStateStorageError.staleGeneration }
      return
    }
    guard candidate.version >= previous.version,
      candidate.lastSequence >= previous.lastSequence,
      candidate.effectiveRevision > previous.effectiveRevision else {
      throw PDSReadStateStorageError.staleGeneration
    }
    if candidate.version == 1, candidate.lastSequence == previous.lastSequence {
      throw PDSReadStateStorageError.staleGeneration
    }
  }

  /// A GC transaction changes only the revision. Unchanged verified roots prove
  /// that neither executable state nor retry receipts changed.
  public static func isMaintenance(previous: ReadStateManifest?, candidate: ReadStateManifest) -> Bool {
    guard let previous, previous.version == 2, candidate.version == 2,
      candidate.effectiveRevision > previous.effectiveRevision else { return false }
    return candidate.lastSequence == previous.lastSequence
      && candidate.stateHead == previous.stateHead
      && candidate.devicesHead == previous.devicesHead
      && candidate.legacyReceiptsHead == previous.legacyReceiptsHead
      && candidate.compactionVersion == previous.compactionVersion
  }
}
