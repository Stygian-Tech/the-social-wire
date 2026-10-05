import FinanceCore
import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("Finance PostgreSQL Corpus parity", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Requires an explicitly disposable migrated PostgreSQL database."))
struct FinancePostgresCorpusIntegrationTests {
  @Test("Finance presentation views preserve identities and recheck exact language, moderation and deletion")
  func currentPresentationAuthority() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "finance-corpus.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let key = UUID().uuidString.lowercased()
    let labeler = "did:example:finance-corpus:\(key)"
    let generation = UUID()
    let now = Date()
    let instrument = FinanceInstrument(id: "fi_\(key)", name: "Fixture Class A", symbol: "FIX", kind: "equity",
      providerID: "fixture:\(key)", exchange: "NYSE", currency: "USD", tradingViewSymbol: "NYSE:FIX")
    let item = WireFeedItem(itemID: key, canonicalURL: "https://example.com/\(key)", representativeURI: nil,
      title: "Fixture earnings", summary: nil, publishedAt: now, thumbnailURL: nil,
      source: WireItemSource(name: "Fixture", domain: "example.com"), reasons: [], provenance: [])
    let candidate = FinanceRankCandidate(item: item, analysis: FinanceArticleAnalysis(eligible: true,
      materiality: "earnings", associations: [FinanceAssociation(instrumentID: instrument.id,
        confidence: 1, evidence: ["structured-metadata"], prominence: 0)], sectorIDs: []), baseScore: 100)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode([candidate]), as: UTF8.self)
    let instrumentPayload = String(decoding: try encoder.encode(instrument), as: UTF8.self)
    let store = PostgresWireCorpusStore(pool: pool, logger: logger)
    do {
      try await pool.query("""
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labeler), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
          first_seen_at, last_seen_at, expires_at, language_code)
        VALUES (\(key), \(item.canonicalURL), 'example.com', 'Fixture', 'Fixture earnings',
          \(now), \(now), \(now.addingTimeInterval(3600)), 'qx')
        """, logger: logger)
      try await pool.query("""
        INSERT INTO finance_instruments (instrument_id, provider_key, payload, updated_at)
        VALUES (\(instrument.id), \(instrument.providerID), \(instrumentPayload)::jsonb, \(now))
        """, logger: logger)
      try await pool.query("""
        INSERT INTO finance_generations (generation_id, source_generation_id, language, algorithm_version,
          generated_at, expires_at, payload, is_active)
        VALUES (\(generation), \(generation), 'qx', 'finance-v1', \(now), \(now.addingTimeInterval(3600)), \(payload)::jsonb, TRUE)
        """, logger: logger)
      let first = try await store.finance(language: "qx", now: now)
      #expect(first.candidates.count == 1)
      #expect(first.instruments == [instrument])
      await #expect(throws: WireCorpusEdgeStoreError.unavailable) {
        _ = try await store.finance(language: "qy", now: now)
      }
      try await pool.query("UPDATE wire_items SET language_code = 'qy' WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.finance(language: "qx", now: now).candidates.isEmpty)
      try await pool.query("UPDATE wire_items SET language_code = 'qx' WHERE canonical_key = \(key)", logger: logger)
      try await pool.query("""
        INSERT INTO wire_labels (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES (\(key), 'block', 'block', 'test', \(now), \(now.addingTimeInterval(3600)))
        """, logger: logger)
      #expect(try await store.finance(language: "qx", now: now).candidates.isEmpty)
      try await pool.query("DELETE FROM wire_labels WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.finance(language: "qx", now: now).candidates.count == 1)
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.finance(language: "qx", now: now).candidates.isEmpty)
    } catch {
      try? await cleanup(pool: pool, logger: logger, key: key, labeler: labeler, generation: generation, instrument: instrument.id)
      throw error
    }
    try await cleanup(pool: pool, logger: logger, key: key, labeler: labeler, generation: generation, instrument: instrument.id)
  }

  private func cleanup(pool: PostgresClient, logger: Logger, key: String, labeler: String, generation: UUID, instrument: String) async throws {
    try await pool.query("DELETE FROM finance_generations WHERE generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM finance_instruments WHERE instrument_id = \(instrument)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: logger)
  }
}
