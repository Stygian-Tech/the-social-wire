import Foundation
import Testing
@testable import IndexingWorkerCore

@Suite("Coordinator cached control health")
struct IndexingWorkerControlEvidenceTests {
  @Test("cached evidence accommodates configured control cadence without unlimited freshness")
  func configuredCadence() throws {
    let config = try IndexingWorkerConfig.load([
      "INDEXING_WORKER_ROLE": "coordinator",
      "INDEXING_ROLE_LEASE_SECONDS": "90",
      "INDEXING_ROLE_LEASE_RENEW_SECONDS": "40",
      "INDEXING_ROLE_STANDBY_RETRY_SECONDS": "50",
    ])
    #expect(config.controlEvidenceMaximumAge == 55)
    #expect(throws: IndexingWorkerConfigError.self) {
      try IndexingWorkerConfig.load([
        "INDEXING_WORKER_ROLE": "coordinator", "INDEXING_ROLE_LEASE_SECONDS": "inf",
      ])
    }
  }

  @Test("both lanes need recent database evidence and repeated reads cannot refresh it")
  func evidenceExpires() async {
    let state = IndexingWorkerLaneState()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(await state.hasRecentControlEvidence(at: now) == false)
    await state.record(.acquired(fencingToken: 1), for: .wire, at: now)
    #expect(await state.hasRecentControlEvidence(at: now) == false)
    await state.record(.contended, for: .appView, at: now)
    #expect(await state.hasRecentControlEvidence(at: now.addingTimeInterval(30)))
    #expect(await state.hasRecentControlEvidence(at: now.addingTimeInterval(31)) == false)
    #expect(await state.hasRecentControlEvidence(at: now.addingTimeInterval(-1)) == false)
    await state.record(.operationStarted, for: .wire, at: now.addingTimeInterval(31))
    #expect(await state.hasRecentControlEvidence(at: now.addingTimeInterval(31)) == false)
  }
}
