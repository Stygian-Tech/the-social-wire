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
    let rollups = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/WireWorkerCore/PostgresWireSignalRollupStore.swift"),
      encoding: .utf8
    )
    let store = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/WireWorkerCore/PostgresWireGenerationStore.swift"),
      encoding: .utf8
    )

    #expect(rollups.contains("baseline_last_signal_at"))
    #expect(rollups.contains("source_collection NOT LIKE 'at.margin.%'"))
    #expect(rollups.contains("source_collection NOT LIKE 'network.cosmik.%'"))
    #expect(store.contains("ranking.version == WireRankingConfig.externalSignalVersion"))
    #expect(store.contains("ELSE r.baseline_shares_24h END"))
    #expect(store.contains("ELSE r.baseline_recommendations_24h END"))
    #expect(store.contains("ELSE r.baseline_last_signal_at END"))
  }
}
