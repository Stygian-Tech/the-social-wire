import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore
@testable import WireCorpusEdge

extension WireCorpusCacheIntegrationTests {
  @Test("empty global and localized generations use the same baseline fallback quality and ranking",
        arguments: [false, true])
  func emptyGenerationsUseBaselineFallbackParity(usesRedis: Bool) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.fallback-baseline-parity")
    let configuration = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let namespace = UUID().uuidString.lowercased()
    let keys = (0..<60).map { "url:\(namespace)-fallback-\($0)" }
    let generations = [UUID(), UUID()]
    let labelSource = "did:example:labeler:\(namespace)"
    let now = Date()
    let blockedDID = "did:example:fallback-blocked:\(namespace)"
    let baselineShares = [30, 5, 3, 1]
    let hourlyShares = [20, 0, 3, 1]
    let recommendations = [10, 0, 0, 0]
    let ages: [TimeInterval] = [3_600, 86_400, 1_800, 7_200]
    var expectedCandidates: [WireCandidate] = []
    do {
      try await pool.query("""
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labelSource), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      for (index, key) in keys.enumerated() {
        let positive = index < 4
        let exclusion = (index - 4) % 4
        let labeled = index == 56 || index == 57
        let externalOnly = !positive && !labeled && exclusion == 0
        let missingMetadata = !positive && !labeled && exclusion == 3
        let baseline = positive ? baselineShares[index] : externalOnly ? 0 : 10
        let hourly = positive ? hourlyShares[index] : baseline
        let recommendation = positive ? recommendations[index] : 0
        let total = positive ? [30, 9_000, 900, 1][index] : 10_000
        let publishedAt = now.addingTimeInterval(index == 58 ? -31 * 86_400 : positive ? -ages[index] : -3_600)
        let confidence = index == 59 ? 0.1 : 0.9
        let domain = "source-\(index).example"
        let canonicalURL = "https://\(domain)/\(namespace)"
        let provenance = missingMetadata ? "[\"bluesky_post\"]" : "[\"standard_site\"]"
        let target = !positive && !labeled && exclusion == 2 ? "unsupported" : missingMetadata ? "external_article" : "standard_site_document"
        let commercial = !positive && !labeled && exclusion == 1 ? "probable_ad" : "normal"
        let author: String? = index == 0 ? blockedDID : nil
        let title = index == 2 ? "Suppressed topic" : "Fallback story \(index)"
        try await pool.query("""
          INSERT INTO wire_items
            (canonical_key, canonical_url, author_key, source_domain, source_name, title, language_code,
             provenance, thumbnail_url, published_at, first_seen_at, last_seen_at, last_signal_at,
             source_confidence, eligible, expires_at, target_kind, commercial_class)
          VALUES (\(key), \(canonicalURL), \(author), \(domain), 'Example', \(title),
            'en', \(provenance)::jsonb, \(index == 1 ? "invalid-image-url" : nil), \(publishedAt), \(publishedAt), \(now), \(now),
            \(confidence), TRUE, \(now.addingTimeInterval(86_400)), \(target), \(commercial))
          """, logger: logger)
        try await pool.query("""
          INSERT INTO wire_signal_rollups
            (canonical_key, shares_24h, recommendations_24h, baseline_last_signal_at,
             baseline_shares_1h, baseline_shares_24h, baseline_recommendations_24h,
             baseline_distinct_actors_1h, baseline_distinct_actors_24h, baseline_distinct_actors_7d,
             baseline_signals_1h, baseline_signals_24h, baseline_signals_7d, updated_at)
          VALUES (\(key), \(total), \(recommendation), \(externalOnly ? nil : now),
            \(hourly), \(baseline), \(recommendation), \(hourly), \(baseline), \(baseline),
            \(hourly), \(baseline), \(baseline), \(now))
          """, logger: logger)
        if positive {
          expectedCandidates.append(WireCandidate(canonicalKey: key, canonicalURL: canonicalURL,
            representativeURI: nil, sourceDomain: domain, authorKey: author, publishedAt: publishedAt,
            firstSeenAt: publishedAt, lastSignalAt: now,
            distinctActors1h: hourly, distinctActors24h: baseline, distinctActors7d: baseline,
            signals1h: hourly, signals24h: baseline, signals7d: baseline,
            recommendations24h: recommendation, shares1h: hourly, shares24h: baseline,
            sourceConfidence: 0.9, isStandardSite: true, targetKind: .standardSiteDocument))
        }
      }
      for (key, value) in zip(keys[56...57], ["block", "graphic"]) {
        try await pool.query("""
          INSERT INTO wire_labels (canonical_key, label_key, label_value, source, applied_at, expires_at)
          VALUES (\(key), \("test:\(value)"), \(value), \(labelSource),
                  \(now), \(now.addingTimeInterval(3_600)))
          """, logger: logger)
      }
      let expected = try WireRanker.rank(candidates: expectedCandidates, asOf: now, config: WireRankingConfig())
      let expectedOrder = expected.items.map { $0.candidate.canonicalKey }
      #expect(expectedOrder.count == 4)
      #expect(expectedOrder.contains(keys[3])) // Fresh standard.site single-share admission.
      #expect(expectedOrder != [keys[1], keys[2], keys[0], keys[3]]) // Old total-signal SQL ordering.
      for (generation, language) in zip(generations, ["und", "en"]) {
        try await pool.query("""
          INSERT INTO wire_rank_generations
            (generation_id, feed_key, language_bucket, status, is_active, config_version,
             generated_at, committed_at, expires_at, candidate_count, ranked_count)
          VALUES (\(generation), 'wire', \(language), 'committed', TRUE, 'wire-v10', \(now), \(now),
            \(now.addingTimeInterval(3600)), 0, 0)
          """, logger: logger)
        try await pool.query("""
          INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
          VALUES ('wire', \(language), \(generation), \(now))
          """, logger: logger)
        try await pool.query("""
          INSERT INTO wire_edition_generations
            (generation_id, algorithm_version, language_bucket, continuation_ordinal, materialized_at)
          VALUES (\(generation), 'wire-v10', \(language), 0, \(now))
          """, logger: logger)
      }
      let commands = CorpusCacheCommands()
      let store = PostgresWireCorpusStore(pool: pool, logger: logger,
        payloadCache: usesRedis ? WireCorpusPayloadCache(commands: commands, environment: "test") : nil)
      for (index, language) in ["und", "en"].enumerated() {
        let page = try await store.feed(language: language, generationID: nil,
          startOrdinal: 0, limit: 20, now: now)
        #expect(page.source == .simplifiedFallback)
        #expect(page.degraded)
        #expect(page.language == language)
        #expect(page.rows.map { $0.item.itemID } == expectedOrder)
        #expect(page.rows.map { $0.item.reasons } == expected.items.map { Array($0.reasonCodes.prefix(2)) })
        #expect(page.rows.first { $0.item.itemID == keys[0] }?.sourceActorKey == blockedDID)
        let result = try await store.edition(language: language, region: nil, now: now)
        #expect(result.edition.source == .simplifiedFallback)
        #expect(result.edition.degraded)
        #expect(result.edition.leadStories.map(\.itemID) == expectedOrder)
        #expect(result.sourceActorKeysByItemID?[keys[0]] == blockedDID)
        // A pinned pagination request must never switch to a different corpus.
        let pinned = try await store.feed(language: language, generationID: generations[index],
          startOrdinal: 0, limit: 20, now: now)
        #expect(pinned.rows.isEmpty)
        #expect(pinned.generationID == generations[index].uuidString.lowercased())
        #expect(pinned.source != .simplifiedFallback)
        let publicAgain = try await store.feed(language: language, generationID: nil,
          startOrdinal: 0, limit: 20, now: now)
        #expect(publicAgain.rows == page.rows)
      }
      for generation in generations {
        try await pool.query("DELETE FROM wire_feed_state WHERE active_generation_id = \(generation)", logger: logger)
        try await pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: logger)
      }
      // More than 50 total-signal rows are present, but only four meet baseline eligibility.
      #expect(!(try await store.catalog(now: now)).available)
    } catch {
      Issue.record("PostgreSQL fallback baseline parity failed: \(String(reflecting: error))")
    }
    for generation in generations {
      try await pool.query("DELETE FROM wire_feed_state WHERE active_generation_id = \(generation)", logger: logger)
      try await pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: logger)
    }
    for key in keys {
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    }
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)", logger: logger)
  }

}

extension WireCorpusCacheIntegrationTests {
  @Test("fallback caps candidates before ranker admission, matching direct generation selection")
  func candidateCapPrecedesAdmission() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-corpus.fallback-cap-test")
    let config = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let namespace = UUID().uuidString.lowercased()
    let prefix = "cap-\(namespace)-"
    let pattern = prefix + "%"
    let labeler = "did:example:cap-\(namespace)"
    let now = Date()
    do {
      try await pool.query("""
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labeler), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      // All rows are serving-eligible. The first 5,001 win candidate ordering but
      // fail source confidence; the final row would rank if admission moved before LIMIT.
      try await pool.query("""
        INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
          provenance, published_at, first_seen_at, last_seen_at, expires_at, language_code,
          source_confidence, target_kind)
        SELECT \(prefix) || n, 'https://example.test/' || \(prefix) || n,
          'example.test', 'Fixture', 'Candidate', '["standard_site"]'::jsonb,
          \(now), \(now), \(now), \(now.addingTimeInterval(3600)), 'en',
          CASE WHEN n = 5002 THEN 0.9 ELSE 0.1 END, 'standard_site_document'
        FROM generate_series(1, 5002) n
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_signal_rollups (canonical_key, baseline_shares_24h, baseline_shares_1h,
          baseline_signals_24h, baseline_signals_1h, baseline_last_signal_at, updated_at)
        SELECT \(prefix) || n, CASE WHEN n = 5002 THEN 5 ELSE 100 END, 0,
          CASE WHEN n = 5002 THEN 5 ELSE 100 END, 0, \(now), \(now)
        FROM generate_series(1, 5002) n
        """, logger: logger)
      let store = PostgresWireCorpusStore(pool: pool, logger: logger)
      for language in ["und", "en"] {
        let page = try await store.feed(language: language, generationID: nil,
          startOrdinal: 0, limit: 50, now: now)
        #expect(page.source == .simplifiedFallback)
        #expect(page.rows.isEmpty)
      }
      let admitted = try await pool.query("""
        SELECT COUNT(*)::bigint FROM wire_serving.fallback_candidates
        WHERE canonical_key LIKE \(pattern) AND baseline_admitted
        """, logger: logger)
      for try await row in admitted { #expect(try row.decode(Int64.self) == 1) }
      #expect(!(try await store.catalog(now: now)).available)
      // The explicit internal budget expands fallback only; omitted callers keep
      // their original page size. Presentation payloads remain bounded on the wire.
      try await pool.query("""
        UPDATE wire_items SET source_confidence = 0.9,
          author_key = 'did:example:fixture-author', summary = repeat('Synthetic story summary. ', 12)
        WHERE canonical_key LIKE \(pattern)
        """, logger: logger)
      let ordinary = try await store.feed(language: "en", generationID: nil,
        startOrdinal: 0, limit: 500, now: now)
      let expanded = try await store.feed(language: "en", generationID: nil,
        startOrdinal: 0, limit: 500, fallbackLimit: 5000, now: now)
      #expect(ordinary.rows.count == 500)
      #expect(expanded.rows.count == 5000)
      #expect(expanded.exhausted)
      let edition = try await store.edition(language: "en", region: nil, fallbackLimit: 5000, now: now)
      #expect(edition.fallbackRows?.count == 5000)
      #expect(edition.edition.leadStories.count <= WireEditionAssembler.maximumLeadStories)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let bytes = try encoder.encode(edition).count
      #expect(bytes < 8 * 1024 * 1024)
      print("TSW124 synthetic 5000-row edition bytes: \(bytes)")

    } catch {
      Issue.record("Corpus candidate cap fixture failed: \(String(reflecting: error))")
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(pattern)", logger: logger)
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: logger)
  }
}
