import FinanceCore
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import WireCore

/// Optional Coordinator work. Its failures cannot revoke an already committed Wire cycle.
actor PostgresFinanceMaterializer {
  private let pool: PostgresClient
  private let logger: Logger
  private let authority: RoleLeaseAuthority?
  private let mode: FinanceFeedMode
  private let rightsConfirmed: Bool
  private let figiIDs: [String]
  private let figi: OpenFIGIAdapter
  private let hasOpenFIGIKey: Bool
  private let crypto: CoinGeckoAdapter
  private let providerPolicy: FinanceCatalogProviderPolicy
  private var lastRefreshAttempt: Date?

  init(pool: PostgresClient, logger: Logger, authority: RoleLeaseAuthority?, environment: [String: String],
    transport: any FinanceHTTPTransport = FinanceRetryingTransport()) {
    self.pool = pool; self.logger = logger; self.authority = authority
    self.mode = FinanceFeedMode(environmentValue: environment["FINANCE_FEED_MODE"])
    self.rightsConfirmed = environment["FINANCE_CATALOG_RIGHTS_CONFIRMED"] == "true"
    self.figiIDs = Array(Set((environment["FINANCE_OPENFIGI_IDS"] ?? FinanceNamedFeeds.seedFIGIs.joined(separator: ","))
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }).sorted())
    self.hasOpenFIGIKey = environment["OPENFIGI_API_KEY"]?.isEmpty == false
    self.figi = OpenFIGIAdapter(transport: transport, apiKey: environment["OPENFIGI_API_KEY"])
    self.crypto = CoinGeckoAdapter(transport: transport)
    self.providerPolicy = FinanceCatalogProviderPolicy(environment: environment)
  }

  func run(asOf: Date) async throws {
    guard mode != .off else { return }
    // Neither catalog nor feed publication is permitted before rights review.
    guard rightsConfirmed else {
      logger.warning("Finance catalog activation awaits reviewed coverage and rights")
      return
    }
    _ = try await refreshCatalogIfDue(asOf: asOf)
    guard let catalog = try await PostgresFinanceCatalogReader.load(pool: pool, logger: logger, providerPolicy: providerPolicy) else { return }
    var languageBinds = PostgresBindings(); languageBinds.append(asOf)
    let languages = try await pool.query(PostgresQuery(unsafeSQL: """
      WITH analysis_pool AS MATERIALIZED (
        SELECT canonical_key FROM finance_article_analysis
        WHERE expires_at>$1 AND payload->>'eligible'='true'
        ORDER BY analyzed_at DESC,canonical_key LIMIT 3000
      )
      SELECT item.language_code FROM analysis_pool analysis JOIN wire_items item
        ON analysis.canonical_key=item.canonical_key
      WHERE \(FinanceCandidateQuality.predicate)
      GROUP BY item.language_code ORDER BY count(*) DESC,item.language_code LIMIT 13
      """, binds: languageBinds), logger: logger)
    for try await row in languages {
      try await materialize(sourceID: UUID(), language: try row.decode(String.self), catalog: catalog, asOf: asOf)
    }
  }

  func refreshCatalogIfDue(asOf: Date) async throws -> FinanceCatalogSnapshot {
    let rows = try await pool.query("""
      SELECT payload::text FROM finance_catalog_snapshots WHERE is_active = TRUE LIMIT 1
      """, logger: logger)
    var previous: FinanceCatalogSnapshot?
    for try await row in rows {
      previous = try JSONDecoder().decode(FinanceCatalogSnapshot.self, from: Data(try row.decode(String.self).utf8))
    }
    if let previous, asOf.timeIntervalSince(previous.generatedAt) < 86_400,
      previous.instruments.allSatisfy({ providerPolicy.permits($0) }),
      Set(figiIDs).isSubset(of: Set(previous.instruments.map(\.providerID))) { return previous }
    if let lastRefreshAttempt, asOf.timeIntervalSince(lastRefreshAttempt) < 3_600 {
      if let previous { return FinanceCatalogSnapshot(version: previous.version, generatedAt: previous.generatedAt, instruments: providerPolicy.filter(previous.instruments)) }
      throw FinanceProviderError.invalidResponse
    }
    lastRefreshAttempt = asOf
    do {
      var securities: [FinanceInstrument] = []
      // Seed reviewed FIGIs explicitly; a provider does not supply a complete licensed universe.
      // Re-map existing FIGIs to preserve listing identity while refreshing symbol metadata.
      var discoveredIDs: [String] = []
      let discovered = try await pool.query("SELECT provider_key FROM finance_instruments WHERE provider_key LIKE 'BBG%' ORDER BY provider_key LIMIT 151", logger: logger)
      for try await row in discovered { discoveredIDs.append(try row.decode(String.self)) }
      let requiredIDs = Set(figiIDs)
      guard requiredIDs.count <= 150 else { throw FinanceProviderError.invalidRequest }
      let discoveredIDsAndPrevious = Set(discoveredIDs + (previous?.instruments ?? [])
        .filter { $0.providerID.hasPrefix("BBG") }.map(\.providerID)).subtracting(requiredIDs).sorted()
      // Required reviewed coverage cannot be starved by ad-hoc searches. Daily provider work stays bounded.
      let boundedIDs = requiredIDs.sorted() + Array(discoveredIDsAndPrevious.prefix(150 - requiredIDs.count))
      for start in stride(from: 0, to: boundedIDs.count, by: 5) {
        if start > 0 && !hasOpenFIGIKey { try await Task.sleep(for: .milliseconds(3100)) }
        securities += try await figi.mapFIGIs(Array(boundedIDs[start..<min(start + 5, boundedIDs.count)]))
      }
      // Entries omitted by the daily request budget are unchanged, not inferred to be delisted.
      let refreshedIDs = Set(boundedIDs)
      securities += (previous?.instruments ?? []).filter { $0.providerID.hasPrefix("BBG") && !refreshedIDs.contains($0.providerID) }
      let coins = providerPolicy.cryptoEnabled ? try await crypto.instruments() : []
      let uniqueSecurities = Dictionary(securities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
      let snapshot = try FinanceCatalogRefresh.candidate(previous: previous,
        securities: Array(uniqueSecurities), crypto: coins, now: asOf)
      let permittedSnapshot = FinanceCatalogSnapshot(version: snapshot.version, generatedAt: snapshot.generatedAt,
        instruments: providerPolicy.filter(snapshot.instruments))
      let payload = String(decoding: try JSONEncoder().encode(permittedSnapshot), as: UTF8.self)
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: self.logger)
        if let authority = self.authority {
          try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger)
        }
        try await connection.query("UPDATE finance_catalog_snapshots SET is_active = FALSE WHERE is_active = TRUE", logger: self.logger)
        try await connection.query("""
          INSERT INTO finance_catalog_snapshots (snapshot_id, version, generated_at, payload, is_active)
          VALUES (\(UUID()), \(snapshot.version), \(asOf), \(payload)::jsonb, TRUE)
          """, logger: self.logger)
        try await connection.query("""
          INSERT INTO finance_instruments (instrument_id, provider_key, payload, updated_at)
          SELECT instrument->>'id',
            CASE WHEN instrument->>'kind' = 'crypto' THEN 'coingecko:' ELSE '' END || (instrument->>'providerID'),
            instrument, \(asOf)
          FROM jsonb_array_elements(\(payload)::jsonb->'instruments') instrument
          ON CONFLICT (instrument_id) DO UPDATE SET payload = EXCLUDED.payload, updated_at = EXCLUDED.updated_at
          """, logger: self.logger)
      }
      return permittedSnapshot
    } catch {
      logger.warning("Finance reference refresh failed; retaining prior catalog")
      if let previous { return FinanceCatalogSnapshot(version: previous.version, generatedAt: previous.generatedAt, instruments: providerPolicy.filter(previous.instruments)) }
      throw error
    }
  }

  func materialize(sourceID: UUID, language: String, catalog: FinanceProjectionCatalog, asOf: Date) async throws {
    let existing = try await pool.query("""
      SELECT generation_id FROM finance_generations
      WHERE source_generation_id = \(sourceID) AND language = \(language) AND expires_at > \(asOf) LIMIT 1
      """, logger: logger)
    for try await _ in existing { return }
    var binds = PostgresBindings()
    binds.append(asOf); binds.append(language); binds.append(catalog.revision)
    binds.append(PostgresFinanceArticleProjector.resolverVersion)
    let rows = try await pool.query(PostgresQuery(unsafeSQL: """
      WITH analysis_pool AS MATERIALIZED (
        SELECT analysis.* FROM finance_article_analysis analysis JOIN wire_items candidate
          ON candidate.canonical_key=analysis.canonical_key
        WHERE analysis.expires_at>$1 AND analysis.catalog_revision=$3 AND analysis.resolver_version=$4
          AND analysis.payload->>'eligible'='true' AND candidate.language_code=$2
        ORDER BY analysis.analyzed_at DESC,analysis.canonical_key LIMIT 3000
      )
      SELECT item.canonical_key,item.canonical_url,item.representative_uri,item.title,item.summary,
        item.published_at,item.thumbnail_url,item.source_name,item.source_domain,item.publication_id,
        item.author_name,item.provenance::text,analysis.payload::text,item.first_seen_at,item.source_confidence,
        item.provenance ? 'standard_site',item.commercial_class,item.commercial_score,
        COALESCE(rollup.baseline_shares_1h,0),COALESCE(rollup.baseline_shares_24h,0),
        COALESCE(rollup.baseline_recommendations_24h,0),COALESCE(rollup.baseline_signals_7d,0),
        COALESCE(rollup.communities_24h,0),COALESCE(rollup.baseline_distinct_likers_24h,0),
        COALESCE(rollup.baseline_likes_1h,0),COALESCE(rollup.baseline_likes_24h,0),
        COALESCE(rollup.distinct_reposters_24h,0),COALESCE(rollup.reposts_1h,0),
        COALESCE(rollup.reposts_24h,0),COALESCE(rollup.positive_feedback_24h,0),
        COALESCE(rollup.negative_feedback_24h,0)
      FROM analysis_pool analysis JOIN wire_items item ON analysis.canonical_key=item.canonical_key
      LEFT JOIN wire_signal_rollups rollup ON rollup.canonical_key=item.canonical_key
      WHERE \(FinanceCandidateQuality.predicate) AND item.language_code=$2
        AND analysis.source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
        AND analysis.catalog_revision=$3 AND analysis.resolver_version=$4 AND analysis.expires_at>$1
      ORDER BY item.updated_at DESC,item.canonical_key LIMIT 3000
      """, binds: binds), logger: logger)
    let decoder = JSONDecoder()
    var stories: [String: WireFeedItem] = [:]
    var analyses: [String: FinanceArticleAnalysis] = [:]
    var wireCandidates: [WireCandidate] = []
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let title = try cells[3].decode(String.self)
      let summary = try cells[4].decode(String?.self)
      let analysis = try decoder.decode(FinanceArticleAnalysis.self, from: Data(try cells[12].decode(String.self).utf8))
      let shares = try cells[19].decode(Int.self)
      let recommendations = try cells[20].decode(Int.self)
      guard analysis.eligible, analysis.materiality != "price-chatter" || shares>=3 || recommendations>=1 else { continue }
      let key = try cells[0].decode(String.self)
      let story = WireFeedItem(itemID: key, canonicalURL: try cells[1].decode(String.self),
        representativeURI: try cells[2].decode(String?.self),title: title,summary: summary,
        publishedAt: try cells[5].decode(Date?.self),thumbnailURL: try cells[6].decode(String?.self),
        source: .init(name: try cells[7].decode(String.self),domain: try cells[8].decode(String.self),
          publication: try cells[9].decode(String?.self),author: try cells[10].decode(String?.self)),
        reasons: [],provenance: try decoder.decode([WireProvenanceKind].self, from: Data(try cells[11].decode(String.self).utf8)))
      stories[key]=story; analyses[key]=analysis
      wireCandidates.append(WireCandidate(canonicalKey: key, canonicalURL: story.canonicalURL,
        representativeURI: story.representativeURI,sourceDomain: story.source.domain,
        publicationID: story.source.publication,authorKey: story.source.author,
        topicKeys: analysis.sectorIDs + (analysis.macroTopics ?? []),publishedAt: story.publishedAt,
        firstSeenAt: try cells[13].decode(Date.self),signals7d: try cells[21].decode(Int.self),
        communities24h: try cells[22].decode(Int.self),recommendations24h: recommendations,
        positiveFeedback24h: try cells[29].decode(Int.self),negativeFeedback24h: try cells[30].decode(Int.self),
        shares1h: try cells[18].decode(Int.self),shares24h: shares,
        distinctLikes24h: try cells[23].decode(Int.self),likes1h: try cells[24].decode(Int.self),
        likes24h: try cells[25].decode(Int.self),distinctReposts24h: try cells[26].decode(Int.self),
        reposts1h: try cells[27].decode(Int.self),reposts24h: try cells[28].decode(Int.self),
        sourceConfidence: try cells[14].decode(Double.self),isStandardSite: try cells[15].decode(Bool.self),
        hasUsableOpenGraphMetadata: true,hasUsableThumbnail: story.thumbnailURL != nil,
        commercialClass: WireCommercialClass(rawValue: try cells[16].decode(String.self)) ?? .probableAd,
        commercialScore: try cells[17].decode(Double.self)))
    }
    let baseline = try WireRanker.rank(candidates: wireCandidates, asOf: asOf, config: FinanceCandidateQuality.ranking)
    let candidates = baseline.items.enumerated().compactMap { index, scored -> FinanceRankCandidate? in
      guard let story=stories[scored.candidate.canonicalKey],let analysis=analyses[story.itemID] else { return nil }
      return .init(item: story,analysis: analysis,baseScore: scored.score,majorGlobal: index<20)
    }
    guard !candidates.isEmpty else { return }
    let candidateEncoder = JSONEncoder()
    candidateEncoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try candidateEncoder.encode(candidates), as: UTF8.self)
    let generationID = UUID()
    let activate = mode.canServeAPI
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: self.logger)
      try await connection.query("SET LOCAL statement_timeout = '15s'", logger: self.logger)
      if let authority = self.authority {
        try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger)
      }
      if activate {
        try await connection.query("""
          UPDATE finance_generations SET is_active = FALSE WHERE language = \(language) AND is_active = TRUE
          """, logger: self.logger)
      }
      try await connection.query("""
        INSERT INTO finance_generations
          (generation_id, source_generation_id, language, algorithm_version, generated_at, expires_at, payload, is_active)
        VALUES (\(generationID), \(sourceID), \(language), 'finance-v1', \(asOf),
          \(asOf.addingTimeInterval(48 * 3600)), \(payload)::jsonb, \(activate))
        """, logger: self.logger)
      try await connection.query("""
        DELETE FROM finance_generations WHERE generation_id IN (
          SELECT generation_id FROM finance_generations WHERE expires_at <= \(asOf)
          ORDER BY expires_at LIMIT 100)
        """, logger: self.logger)
      try await connection.query("""
        DELETE FROM finance_catalog_snapshots WHERE snapshot_id IN (
          SELECT snapshot_id FROM finance_catalog_snapshots
          WHERE is_active = FALSE AND generated_at < \(asOf.addingTimeInterval(-7 * 86_400))
          ORDER BY generated_at LIMIT 20)
        """, logger: self.logger)
    }
    logger.info("Finance generation committed", metadata: ["language": .string(language),
      "candidates": .stringConvertible(candidates.count), "activated": .stringConvertible(activate)])
  }
}
