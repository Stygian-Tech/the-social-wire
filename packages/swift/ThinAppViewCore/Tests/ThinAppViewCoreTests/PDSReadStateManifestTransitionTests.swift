import ReadStateCore
import Testing
@testable import ThinAppViewCore

@Suite("PDS manifest maintenance fences")
struct PDSReadStateManifestTransitionTests {
  private func manifest(_ revision: Int64, sequence: Int64 = 5,
                        root: ReadStateReference? = nil) -> ReadStateManifest {
    ReadStateManifest(generation: "v2", revision: revision, lastSequence: sequence,
      stateHead: root, devicesHead: nil, legacyReceiptsHead: nil)
  }

  @Test func upgradeMustAdvancePastLegacySequence() throws {
    let legacy = ReadStateManifest(generation: "v1", lastSequence: 5, head: nil)
    #expect(throws: PDSReadStateStorageError.staleGeneration) {
      try PDSReadStateManifestTransition.validate(previous: legacy, previousCID: "old",
        candidate: manifest(5), candidateCID: "new")
    }
    try PDSReadStateManifestTransition.validate(previous: legacy, previousCID: "old",
      candidate: manifest(6), candidateCID: "new")
  }

  @Test func maintenanceInvalidatesPausedWriterWithoutAdvancingActions() throws {
    let old = manifest(6)
    let maintenance = manifest(7)
    try PDSReadStateManifestTransition.validate(previous: old, previousCID: "old",
      candidate: maintenance, candidateCID: "gc")
    #expect(PDSReadStateManifestTransition.isMaintenance(previous: old, candidate: maintenance))
    #expect(throws: PDSReadStateStorageError.staleGeneration) {
      try PDSReadStateManifestTransition.validate(previous: maintenance, previousCID: "gc",
        candidate: manifest(7, sequence: 6), candidateCID: "paused")
    }
    let root = ReadStateReference(uri: "at://did:plc:viewer/app.thesocialwire.readStateChunk/a", cid: "root")
    #expect(!PDSReadStateManifestTransition.isMaintenance(previous: old, candidate: manifest(7, root: root)))
  }

  @Test func downgradesAndRewindsFailAndExactRetrySucceeds() throws {
    let current = manifest(9)
    try PDSReadStateManifestTransition.validate(previous: current, previousCID: "same",
      candidate: current, candidateCID: "same")
    for candidate in [manifest(10, sequence: 4), manifest(8),
      ReadStateManifest(generation: "v1", lastSequence: 20, head: nil)] {
      #expect(throws: PDSReadStateStorageError.staleGeneration) {
        try PDSReadStateManifestTransition.validate(previous: current, previousCID: "current",
          candidate: candidate, candidateCID: "candidate")
      }
    }
  }
}
