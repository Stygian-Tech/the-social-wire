import Foundation
import Testing
import WireCore

@testable import WireWorkerCore

@Suite("Wire candidate query rollout")
struct WireCandidateQueryTests {
  @Test("only opted-in global reads project metadata before the join")
  func globalProjectionGate() {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let original = PostgresWireCandidateQuery.make(
      languageBucket: "und", limit: 5000, ranking: .init(), asOf: now,
      projectGlobalMetadata: false)
    let projected = PostgresWireCandidateQuery.make(
      languageBucket: "und", limit: 5000, ranking: .init(), asOf: now,
      projectGlobalMetadata: true)
    #expect(!original.sql.contains("OFFSET 0"))
    #expect(original.sql.contains("LEFT JOIN wire_link_metadata_cache metadata ON"))
    #expect(projected.sql.contains("FROM wire_link_metadata_cache metadata OFFSET 0"))
    #expect(projected.sql.contains("COALESCE(metadata.has_usable_open_graph, FALSE)"))
    #expect(original.binds == projected.binds)
    #expect(projected.binds.count == 5)
    for parameter in 1...5 { #expect(projected.sql.contains("$\(parameter)")) }
  }

  @Test("language-specific and unknown-language queries keep the original reader", arguments: ["en", "ja", "zz", "en' OR TRUE --"])
  func selectiveQueryUnchanged(language: String) {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let original = PostgresWireCandidateQuery.make(
      languageBucket: language, limit: 7, ranking: .externalSignalsV11(), asOf: now,
      projectGlobalMetadata: false)
    let enabled = PostgresWireCandidateQuery.make(
      languageBucket: language, limit: 7, ranking: .externalSignalsV11(), asOf: now,
      projectGlobalMetadata: true)
    #expect(enabled == original)
    #expect(!enabled.sql.contains("OFFSET 0"))
    #expect(!enabled.sql.contains("'" + language + "'"))
    #expect(enabled.binds.count == 5)
  }
}
