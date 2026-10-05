import AsyncHTTPClient
import FinanceCore
import Foundation
import GatewayCore
import Logging
import PostgresNIO
import Testing
import ThinAppViewCore
import WireCore
@testable import AppView

@Suite("Finance PostgreSQL serving", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Set WIRE_TEST_DATABASE_URL to an explicitly disposable migrated PostgreSQL database."
))
struct FinancePostgresServingIntegrationTests {
  @Test("Finance availability does not depend on the public Wire catalog")
  func independentAvailability() async throws {
    try await withFixture(visible: true) { fixture in
      let wireCatalog = try await fixture.wire.getCatalog(now: fixture.now)
      #expect(!wireCatalog.available)
      let availability = try await fixture.store.availability(now: fixture.now)
      #expect(availability.enabled)
      #expect(availability.available)
    }
  }

  @Test("obsolete topic evidence is revalidated even when the article is unchanged")
  func obsoleteTopicEvidence() async throws {
    try await withFixture(legacyTopicFalsePositive: true) { fixture in
      let page = try await fixture.store.page(cursor: nil, limit: 50, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(page.items.count == 5)
      #expect(!page.items.contains { $0.story.itemID == fixture.items[5].itemID })
    }
  }

  @Test("v2 cooking evidence is rejected from source imports and retained personalized snapshots")
  func obsoleteCookingEvidence() async throws {
    try await withFixture(legacyCookingFalsePositive: true) { fixture in
      let first = try await fixture.store.page(cursor: nil, limit: 1, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      let cursor = try #require(first.cursor)
      let snapshotID = try #require(UUID(uuidString: first.generationId))
      let retained = try await fixture.pool.query("""
        SELECT count(*) FROM finance_personalized_snapshots snapshot,
          jsonb_array_elements(snapshot.payload) candidate
        WHERE snapshot.snapshot_id=\(snapshotID)
          AND candidate->'analysis'->>'resolverVersion'='finance-resolver-v2'
          AND candidate->'item'->>'title'='How to make chicken stock for soup'
          AND (candidate->'analysis'->>'eligible')::boolean=TRUE
        """, logger: fixture.logger)
      for try await row in retained { #expect(try row.decode(Int64.self) == 1) }
      let continuation = try await fixture.store.page(cursor: cursor, limit: 20, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(continuation.generationId == first.generationId)
      let combined = first.items + continuation.items
      #expect(combined.count == 5)
      #expect(combined.allSatisfy { $0.story.title.contains("inflation") })
      #expect(!combined.contains { $0.story.itemID == fixture.items[5].itemID })
      // The unchanged article must stay excluded on reuse of an existing snapshot.
      let repeated = try await fixture.store.page(cursor: nil, limit: 50, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(repeated.generationId == first.generationId)
      #expect(repeated.items.map(\.story.itemID) == combined.map(\.story.itemID))
    }
  }

  @Test("personalized snapshots bind viewer, preference, language and feed and recheck current moderation/deletions")
  func immutableSnapshotContextAndCurrentModeration() async throws {
    try await withFixture { fixture in
      let first = try await fixture.store.page(cursor: nil, limit: 1, language: "en-US",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(first.items.first?.story.itemID == fixture.items[1].itemID)
      #expect(first.preferenceRevision == FinanceIdentity.preferenceFingerprint(instrumentIDs: [fixture.instrument.id], sectorIDs: []) + ":providers-reference-v1")
      let cursor = try #require(first.cursor)
      let repeatFirst = try await fixture.store.page(cursor: nil, limit: 1, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(repeatFirst.generationId == first.generationId)
      #expect(repeatFirst.items == first.items)
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: cursor, limit: 2, language: "en",
          viewerDID: fixture.otherViewer, refresh: false, now: fixture.now)
      }
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: cursor, limit: 2, language: "fr",
          viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      }
      let wireCursor = try WireCursorCodec(secret: fixture.secret).encode(
        WireCursor(generationID: first.generationId, language: "en", nextOrdinal: 1))
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: wireCursor, limit: 2, language: "en",
          viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      }
      // Suppress a story for this viewer and remove another after the immutable
      // snapshot was committed. Continuation must inspect current item access.
      await fixture.wire.suppress(fixture.items[0].itemID, viewer: fixture.viewer)
      await fixture.wire.remove(fixture.items[2].itemID)
      let continuation = try await fixture.store.page(cursor: cursor, limit: 20, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(!continuation.items.contains { $0.story.itemID == fixture.items[0].itemID || $0.story.itemID == fixture.items[2].itemID })
      #expect(continuation.items.map(\.story.itemID).count == 3)
      #expect(continuation.generationId == first.generationId)
      #expect(continuation.cursor == nil)
      try await fixture.pool.query("DELETE FROM finance_selections WHERE viewer_did = \(fixture.viewer)", logger: fixture.logger)
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: cursor, limit: 2, language: "en",
          viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      }
      let changed = try await fixture.store.page(cursor: nil, limit: 1, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(changed.preferenceRevision != first.preferenceRevision)
      #expect(changed.generationId != first.generationId)
      let changedCursor = try #require(changed.cursor)
      let changedID = try #require(UUID(uuidString: changed.generationId))
      try await fixture.pool.query("UPDATE finance_personalized_snapshots SET expires_at = \(fixture.now.addingTimeInterval(-1)) WHERE snapshot_id = \(changedID)", logger: fixture.logger)
      await #expect(throws: WireServingError.cursorExpired) {
        _ = try await fixture.store.page(cursor: changedCursor, limit: 2, language: "en",
          viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      }
    }
  }

  @Test("safe exact-language fallback preserves degradation across personalized continuation")
  func fallbackContinuation() async throws {
    try await withFixture(usesCorpus: false) { fixture in
      let page = try await fixture.store.page(cursor: nil, limit: 1, language: "qz",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(page.language == "qz")
      #expect(page.source == .simplifiedFallback)
      #expect(page.degraded)
      let cursor = try #require(page.cursor)
      let next = try await fixture.store.page(cursor: cursor, limit: 20, language: "qz",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(next.generationId == page.generationId)
      #expect(next.source == .simplifiedFallback)
      #expect(next.degraded)
      #expect(next.items.count == fixture.items.count - 1)
      #expect(next.items.allSatisfy { $0.story.title.contains("inflation") })
    }
  }

  @Test("publisher changes invalidate associations in retained personalized snapshots")
  func changedPublisherInvalidatesAnalysis() async throws {
    try await withFixture { fixture in
      let first = try await fixture.store.page(cursor: nil, limit: 1, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(first.items.first?.instruments.count == 1)
      let original = fixture.items[1]
      let changed = WireFeedItem(itemID: original.itemID, canonicalURL: original.canonicalURL,
        representativeURI: original.representativeURI, title: original.title, summary: original.summary,
        publishedAt: original.publishedAt, thumbnailURL: original.thumbnailURL,
        source: .init(name: original.source.name, domain: "different-publisher.example",
          publication: original.source.publication, author: original.source.author),
        reasons: original.reasons, provenance: original.provenance)
      await fixture.wire.replace(changed)
      let refreshed = try await fixture.store.page(cursor: nil, limit: 1, language: "en",
        viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(refreshed.generationId == first.generationId)
      #expect(refreshed.items.first?.story.source.domain == changed.source.domain)
      #expect(refreshed.items.first?.instruments.isEmpty == true)
    }
  }

  @Test("Wire refuses a correctly signed cursor owned by a different feed")
  func wireGenerationOwnership() async throws {
    try await withFixture { fixture in
      let generation = UUID()
      let labeler = fixture.viewer + "-labeler"
      do {
        try await fixture.pool.query("""
          INSERT INTO wire_label_refresh_state (source_did, endpoint_host, last_attempted_at, last_successful_at,
            target_count, label_count, is_current)
          VALUES (\(labeler), 'labels.example', \(fixture.now), \(fixture.now), 0, 0, TRUE)
          """, logger: fixture.logger)
        try await fixture.pool.query("""
          INSERT INTO wire_rank_generations
            (generation_id, feed_key, language_bucket, status, is_active, config_version,
             generated_at, committed_at, expires_at, candidate_count, ranked_count)
          VALUES (\(generation), 'finance', 'qw', 'committed', TRUE, 'finance-v1',
            \(fixture.now), \(fixture.now), \(fixture.now.addingTimeInterval(3600)), 0, 0)
          """, logger: fixture.logger)
        let wire = try PostgresWireFeedStore(pool: fixture.pool, logger: fixture.logger,
          cursorSecret: fixture.secret, mode: .visible, moderationCache: WireViewerModerationCache())
        let cursor = try WireCursorCodec(secret: fixture.secret).encode(
          WireCursor(generationID: generation.uuidString.lowercased(), language: "qw", nextOrdinal: 0))
        await #expect(throws: WireServingError.cursorExpired) {
          _ = try await wire.getFeed(cursor: cursor, limit: 10, language: "qw", viewerDid: nil, now: fixture.now)
        }
      } catch {
        _ = try? await fixture.pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: fixture.logger)
        _ = try? await fixture.pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: fixture.logger)
        throw error
      }
      try await fixture.pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: fixture.logger)
    }
  }

  @Test("disabled crypto cannot leak from retained rows, remote imports or personalize source associations")
  func disabledCryptoPresentation() async throws {
    try await withFixture(cryptoInstrument: true) { fixture in
      let payload = String(decoding: try JSONEncoder().encode(fixture.instrument), as: UTF8.self)
      try await fixture.pool.query("INSERT INTO finance_instruments (instrument_id,provider_key,payload,updated_at) VALUES (\(fixture.instrument.id),\("coingecko:" + fixture.instrument.providerID),\(payload)::jsonb,\(fixture.now))", logger: fixture.logger)
      #expect(try await fixture.store.instruments(query: fixture.instrument.id, now: fixture.now).isEmpty)
      let page = try await fixture.store.page(cursor: nil, limit: 6, language: "en", viewerDID: fixture.viewer, refresh: false, now: fixture.now)
      #expect(page.items.first?.story.itemID == fixture.items[0].itemID)
      #expect(page.items.allSatisfy { $0.instruments.isEmpty })
      #expect(try await fixture.store.instruments(query: fixture.instrument.id, now: fixture.now).isEmpty)
    }
  }

  @Test("named feeds share ordering but keep cursors and current moderation viewer scoped")
  func namedSharedOrdering() async throws {
    try await withFixture(namedStories: true) { fixture in
      let feed = "instrument:" + fixture.instrument.id
      let first = try await fixture.store.page(cursor: nil, limit: 1, language: "en", viewerDID: fixture.viewer,
        refresh: false, now: fixture.now, feed: feed)
      #expect(first.feedId == feed)
      #expect(first.preferenceRevision.utf8.count <= 128)
      #expect(first.items.first?.story.itemID == fixture.items[1].itemID)
      let cursor = try #require(first.cursor)
      let other = try await fixture.store.page(cursor: nil, limit: 1, language: "en", viewerDID: fixture.otherViewer,
        refresh: false, now: fixture.now, feed: feed)
      #expect(first.generationId == other.generationId)
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: cursor, limit: 2, language: "en", viewerDID: fixture.otherViewer,
          refresh: false, now: fixture.now, feed: feed)
      }
      await #expect(throws: WireServingError.invalidCursor) {
        _ = try await fixture.store.page(cursor: cursor, limit: 2, language: "en", viewerDID: fixture.viewer,
          refresh: false, now: fixture.now, feed: "finance")
      }
      await fixture.wire.suppress(fixture.items[2].itemID, viewer: fixture.viewer)
      let suppressed = try await fixture.store.page(cursor: cursor, limit: 20, language: "en", viewerDID: fixture.viewer,
        refresh: false, now: fixture.now, feed: feed)
      #expect(suppressed.items.isEmpty)
      let otherCursor = try #require(other.cursor)
      let allowed = try await fixture.store.page(cursor: otherCursor, limit: 20, language: "en", viewerDID: fixture.otherViewer,
        refresh: false, now: fixture.now, feed: feed)
      #expect(allowed.items.map(\.story.itemID) == [fixture.items[2].itemID])
      let unrelated = try await fixture.store.page(cursor: nil, limit: 20, language: "en", viewerDID: fixture.viewer,
        refresh: false, now: fixture.now, feed: "industry:energy")
      #expect(unrelated.items.isEmpty)
      #expect(unrelated.cursor == nil)
      #expect(try await fixture.store.availability(now: fixture.now).feeds.contains { $0.id == feed })
    }
  }

  @Test("a named-first fallback import retains the full global source")
  func namedFallbackPreservesGlobal() async throws {
    try await withFixture(usesCorpus: false, namedStories: true) { fixture in
      let payload = String(decoding: try JSONEncoder().encode(fixture.instrument), as: UTF8.self)
      try await fixture.pool.query("INSERT INTO finance_instruments (instrument_id,provider_key,payload,updated_at) VALUES (\(fixture.instrument.id),\(fixture.instrument.providerID),\(payload)::jsonb,\(fixture.now))", logger: fixture.logger)
      let named = try await fixture.store.page(cursor: nil, limit: 20, language: "en", viewerDID: fixture.viewer,
        refresh: false, now: fixture.now, feed: "instrument:" + fixture.instrument.id)
      #expect(named.items.count == 2)
      let global = try await fixture.store.page(cursor: nil, limit: 20, language: "en", viewerDID: fixture.viewer,
        refresh: false, now: fixture.now)
      #expect(global.items.count == 6)
      #expect(global.items.contains { $0.story.itemID == fixture.items[0].itemID })
    }
  }

  private func withFixture(usesCorpus: Bool = true, cryptoInstrument: Bool = false, visible: Bool = false, legacyTopicFalsePositive: Bool = false, legacyCookingFalsePositive: Bool = false, namedStories: Bool = false, _ body: @Sendable (FinanceServingFixture) async throws -> Void) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "finance-postgres.test")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let run = Task { await pool.run() }
    defer { run.cancel() }
    await Task.yield()
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let namespace = UUID().uuidString.lowercased()
    let viewer = "did:example:finance:\(namespace)"
    let other = viewer + "-other"
    let sourceID = UUID()
    let now = Date()
    let instrument = FinanceInstrument(id: "fin_\(namespace)", name: "Finance Fixture", symbol: "FIX", kind: cryptoInstrument ? "crypto" : "equity", providerID: "fixture:\(namespace)")
    let items = (0..<6).map { index in
      WireFeedItem(itemID: "url:finance-\(namespace)-\(index)", canonicalURL: "https://example.com/\(namespace)/\(index)",
        representativeURI: nil, title: legacyCookingFalsePositive && index == 5 ? "How to make chicken stock for soup" : legacyTopicFalsePositive && index == 5 ? "Skater culture and wearing a helmet" : namedStories && [1,2].contains(index) ? "Finance Fixture revenue reporting \(index)" : "Global inflation reporting \(index)",
        summary: legacyTopicFalsePositive && index == 5 ? "This woman has a large following on social media." : nil, publishedAt: now,
        thumbnailURL: nil, source: WireItemSource(name: "Fixture", domain: "example.com"), reasons: [], provenance: [])
    }
    let candidates = items.enumerated().map { ordinal, item in
      FinanceRankCandidate(item: item, analysis: FinanceArticleAnalysis(eligible: true, materiality: "reporting",
        associations: (ordinal == 1 || namedStories && ordinal == 2) ? [FinanceAssociation(instrumentID: instrument.id, confidence: 1, evidence: ["structured-metadata"], prominence: 0)] : [],
        sectorIDs: [], resolverVersion: legacyCookingFalsePositive ? "finance-resolver-v2" : legacyTopicFalsePositive ? "finance-resolver-v1" : FinanceResolver.version),
        baseScore: Double(100 - ordinal * 10), majorGlobal: ordinal == 5)
    }
    let source = FinanceSourceGeneration(generationId: sourceID.uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 3600), language: "en", candidates: candidates, instruments: [instrument])
    let wire = FinanceServingWireStub(items: items, now: now)
    let projection = FinanceSelectionProjection(pool: pool,
      repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger)
    let secret = String(repeating: "f", count: 32)
    let config = try FinanceDiscoveryConfig.fromEnvironment(["FINANCE_FEED_MODE": visible ? "visible" : "api", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "FINANCE_CURSOR_HMAC_SECRET": secret])
    let store = try PostgresFinanceFeedStore(pool: pool, logger: logger, config: config, wire: wire,
      selections: projection, transport: usesCorpus ? FinanceServingCorpusStub(source: source) : nil)
    let fixture = FinanceServingFixture(pool: pool, logger: logger, wire: wire, store: store, viewer: viewer,
      otherViewer: other, instrument: instrument, items: items, secret: secret, now: now)
    do {
      for did in [viewer, other] {
        try await pool.query("INSERT INTO finance_selection_sync (viewer_did, synced_at) VALUES (\(did), \(now))", logger: logger)
      }
      let key = FinanceIdentity.selectionRecordKey(kind: "instrument", id: instrument.id)
      try await pool.query("INSERT INTO finance_selections (viewer_did, record_key, kind, reference, updated_at) VALUES (\(viewer), \(key), 'instrument', \(instrument.id), \(now))", logger: logger)
      try await body(fixture)
    } catch {
      try? await cleanup(fixture, sourceID: sourceID)
      try? await http.shutdown()
      throw error
    }
    try await cleanup(fixture, sourceID: sourceID)
    try await http.shutdown()
  }

  private func cleanup(_ fixture: FinanceServingFixture, sourceID: UUID) async throws {
    for did in [fixture.viewer, fixture.otherViewer] {
      try await fixture.pool.query("DELETE FROM finance_selections WHERE viewer_did = \(did)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM finance_selection_sync WHERE viewer_did = \(did)", logger: fixture.logger)
    }
    let scope = try WireActorHasher(secret: Data(fixture.secret.utf8)).hash(fixture.viewer)
    let rows = try await fixture.pool.query("DELETE FROM finance_personalized_snapshots WHERE viewer_scope = \(scope) RETURNING source_generation_id", logger: fixture.logger)
    var sourceIDs = Set([sourceID])
    for try await row in rows { sourceIDs.insert(try row.decode(UUID.self)) }
    for id in sourceIDs {
      try await fixture.pool.query("DELETE FROM finance_personalized_snapshots WHERE source_generation_id = \(id)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM finance_generations WHERE generation_id = \(id)", logger: fixture.logger)
    }
    try await fixture.pool.query("DELETE FROM finance_instruments WHERE instrument_id = \(fixture.instrument.id)", logger: fixture.logger)
  }
}

private struct FinanceServingFixture: Sendable {
  let pool: PostgresClient
  let logger: Logger
  let wire: FinanceServingWireStub
  let store: PostgresFinanceFeedStore
  let viewer: String
  let otherViewer: String
  let instrument: FinanceInstrument
  let items: [WireFeedItem]
  let secret: String
  let now: Date
}

private actor FinanceServingWireStub: WireFeedStore {
  private var items: [String: WireFeedItem]
  private let order: [String]
  private var suppressed: [String: Set<String>] = [:]
  private let now: Date
  init(items: [WireFeedItem], now: Date) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) }); self.order = items.map(\.itemID); self.now = now }
  func suppress(_ id: String, viewer: String) { suppressed[viewer, default: []].insert(id) }
  func remove(_ id: String) { items.removeValue(forKey: id) }
  func replace(_ item: WireFeedItem) { items[item.itemID] = item }
  func getItem(itemId: String, viewerDid: String?) async throws -> WireItemDetail? {
    if let viewerDid, suppressed[viewerDid]?.contains(itemId) == true { return nil }
    return items[itemId].map { WireItemDetail(item: $0) }
  }
  func getFeed(cursor: String?, limit: Int, language: String?, viewerDid: String?, now: Date) async throws -> WirePage {
    WirePage(generationID: UUID().uuidString.lowercased(), generatedAt: now, language: language ?? "und", cursor: nil,
      source: .simplifiedFallback, degraded: true, items: order.compactMap { items[$0] })
  }
  func getCatalog(now: Date) async throws -> WireFeedCatalog {
    WireFeedCatalog(enabled: false, available: false, supportedLanguages: [])
  }
  func getEdition(language: String?, region: WireViewerRegion?, viewerDid: String?, now: Date) async throws -> WireEdition { throw WireServingError.unavailable }
}

private struct FinanceServingCorpusStub: WireCorpusTransport {
  let source: FinanceSourceGeneration
  func get(target: String) async throws -> WireCorpusTransportResponse {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return WireCorpusTransportResponse(statusCode: 200, contractVersion: 3, body: try encoder.encode(source))
  }
}
