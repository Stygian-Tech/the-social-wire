import Foundation
import Testing

@Suite("External Wire signal rollup isolation")
struct WireExternalSignalRollupContractTests {
  @Test("v10 reads external-free rollups while v11 reads inclusive rollups")
  func versionedRollupInputs() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let processor = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/WireWorker/PostgresWireInboxProcessor.swift"),
      encoding: .utf8
    )
    let store = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/WireWorker/PostgresWireGenerationStore.swift"),
      encoding: .utf8
    )

    #expect(processor.contains("baseline_last_signal_at"))
    #expect(processor.contains("source_collection NOT LIKE 'at.margin.%'"))
    #expect(processor.contains("source_collection NOT LIKE 'network.cosmik.%'"))
    #expect(store.contains("ranking.version == WireRankingConfig.externalSignalVersion"))
    #expect(store.contains("ELSE r.baseline_shares_24h END"))
    #expect(store.contains("ELSE r.baseline_recommendations_24h END"))
    #expect(store.contains("ELSE r.baseline_last_signal_at END"))
  }
}
