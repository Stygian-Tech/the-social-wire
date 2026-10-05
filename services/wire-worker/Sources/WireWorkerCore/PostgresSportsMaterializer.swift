import SportsCore
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import WireCore

/// Optional Coordinator work. Its failures cannot revoke an already committed Wire cycle.
actor PostgresSportsMaterializer {
  private let pool: PostgresClient
  private let logger: Logger
  private let authority: RoleLeaseAuthority?
  private let mode: SportsFeedMode

  init(pool: PostgresClient, logger: Logger, authority: RoleLeaseAuthority?, environment: [String: String]) {
    self.pool = pool; self.logger = logger; self.authority = authority
    self.mode = SportsFeedMode(environmentValue: environment["SPORTS_FEED_MODE"])
  }

  func run(asOf: Date) async throws {
    guard mode != .off else { return }
    _ = try await refreshCatalogIfDue(asOf: asOf)
    guard let catalog = try await PostgresSportsCatalogReader.load(pool: pool, logger: logger) else { return }
    var languageBinds = PostgresBindings(); languageBinds.append(asOf)
    let languages = try await pool.query(PostgresQuery(unsafeSQL: """
      WITH recent_keys AS MATERIALIZED (
        SELECT canonical_key FROM wire_items
        WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document')
          AND commercial_class<>'probable_ad' AND source_confidence>=0.75
        ORDER BY updated_at DESC,canonical_key LIMIT 1000
      ), recent_languages AS (
        SELECT item.language_code AS language,count(*) AS weight
        FROM recent_keys keys JOIN wire_items item ON item.canonical_key=keys.canonical_key
        JOIN sports_article_analysis analysis ON analysis.canonical_key=item.canonical_key
        WHERE analysis.expires_at>$1 AND analysis.payload->>'eligible'='true'
          AND \(SportsCandidateQuality.predicate)
        GROUP BY item.language_code
      ), retained_languages AS (
        SELECT language,max(jsonb_array_length(payload)) AS weight
        FROM sports_generations WHERE expires_at>$1 GROUP BY language
      )
      SELECT language FROM (
        SELECT language,weight FROM recent_languages
        UNION ALL SELECT language,weight FROM retained_languages
      ) available GROUP BY language ORDER BY sum(weight) DESC,language LIMIT 13
      """, binds: languageBinds), logger: logger)
    for try await row in languages {
      try await materialize(sourceID: UUID(), language: try row.decode(String.self), catalog: catalog, asOf: asOf)
    }
  }

  func refreshReviewedCatalog(asOf: Date) async throws {
    guard mode != .off else { return }
    _ = try await refreshCatalogIfDue(asOf: asOf)
  }

  func refreshCatalogIfDue(asOf: Date) async throws -> SportsCatalogSnapshot {
    if let current = try await PostgresSportsCatalogReader.load(pool: pool, logger: logger),
      !SportsCatalogRefreshPolicy.shouldRefresh(current.snapshot, asOf: asOf) { return current.snapshot }
    let previous = try await PostgresSportsCatalogReader.load(pool: pool, logger: logger)
    let imported = previous?.snapshot.entities.filter { !$0.providerIDs.isEmpty } ?? []
    let previousByID = Dictionary((previous?.snapshot.entities ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let reviewed = SportsReviewedCatalog.entities.map { definition in
      SportsReviewedCatalogMerge.definition(definition, existing: previousByID[definition.id])
    }
    let reviewedIDs = Set(reviewed.map(\.id))
    let snapshot = SportsCatalogSnapshot(version: try SportsCatalogSnapshot.revision(entities: reviewed + imported.filter { !reviewedIDs.contains($0.id) }),
      generatedAt: asOf, entities: reviewed + imported.filter { !reviewedIDs.contains($0.id) })
    let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    try await pool.withTransaction(logger: logger) { connection in
      if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
      try await connection.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: self.logger)
      try await connection.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(UUID()),\(snapshot.version),\(asOf),\(payload)::jsonb,TRUE)", logger: self.logger)
      try await connection.query("""
        INSERT INTO sports_entities(entity_id,payload,updated_at)
        SELECT entity->>'id',entity,\(asOf) FROM jsonb_array_elements(\(payload)::jsonb->'entities') entity
        ON CONFLICT(entity_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at
        """, logger: self.logger)
    }
    return snapshot
  }

  func materialize(sourceID: UUID, language: String, catalog: SportsProjectionCatalog, asOf: Date) async throws {
    let existing = try await pool.query("""
      SELECT generation_id FROM sports_generations
      WHERE source_generation_id = \(sourceID) AND language = \(language) AND expires_at > \(asOf) LIMIT 1
      """, logger: logger)
    for try await _ in existing { return }
    var binds = PostgresBindings()
    binds.append(asOf); binds.append(language); binds.append(catalog.revision)
    binds.append(PostgresSportsArticleProjector.resolverVersion)
    let rows = try await pool.query(PostgresQuery(unsafeSQL: """
      WITH prior_generation AS MATERIALIZED (
        SELECT payload FROM sports_generations
        WHERE language=$2 AND expires_at>$1
        ORDER BY jsonb_array_length(payload) DESC,generated_at DESC LIMIT 1
      ), prior_keys AS MATERIALIZED (
        SELECT candidate->'item'->>'itemId' AS canonical_key
        FROM prior_generation CROSS JOIN LATERAL jsonb_array_elements(payload) candidate LIMIT 3000
      ), recent_keys AS MATERIALIZED (
        SELECT canonical_key FROM wire_items
        WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document')
          AND commercial_class<>'probable_ad' AND source_confidence>=0.75
        ORDER BY updated_at DESC,canonical_key LIMIT 1000
      ), candidate_keys AS MATERIALIZED (
        SELECT canonical_key FROM prior_keys UNION SELECT canonical_key FROM recent_keys
      ), analysis_pool AS MATERIALIZED (
        SELECT analysis.* FROM candidate_keys keys
        JOIN sports_article_analysis analysis ON analysis.canonical_key=keys.canonical_key
        JOIN wire_items candidate ON candidate.canonical_key=analysis.canonical_key
        WHERE analysis.expires_at>$1 AND analysis.payload->>'eligible'='true' AND candidate.language_code=$2
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
        COALESCE(rollup.negative_feedback_24h,0),
        analysis.catalog_revision=$3 AND analysis.resolver_version=$4
      FROM analysis_pool analysis JOIN wire_items item ON analysis.canonical_key=item.canonical_key
      LEFT JOIN wire_signal_rollups rollup ON rollup.canonical_key=item.canonical_key
      WHERE \(SportsCandidateQuality.predicate) AND item.language_code=$2
        AND analysis.source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
        AND analysis.expires_at>$1
      ORDER BY item.updated_at DESC,item.canonical_key LIMIT 3000
      """, binds: binds), logger: logger)
    let decoder = JSONDecoder()
    var stories: [String: WireFeedItem] = [:]
    var analyses: [String: SportsArticleAnalysis] = [:]
    var wireCandidates: [WireCandidate] = []
    let entityIndex = SportsEntityIndex(entities: catalog.snapshot.entities)
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let title = try cells[3].decode(String.self)
      let summary = try cells[4].decode(String?.self)
      let projected = try decoder.decode(SportsArticleAnalysis.self, from: Data(try cells[12].decode(String.self).utf8))
      // Catalog activation must not replace broad coverage with a partial sweep.
      // Prior eligible evidence is bounded by the same 3000-row pool and current
      // quality/fingerprint gates; its old associations are never published.
      let current = try cells[31].decode(Bool.self)
        && projected.resolverVersion == SportsResolver.version
        && projected.associations.allSatisfy { $0.resolverVersion == SportsResolver.version }
      let analysis = current ? projected : SportsResolver.analyze(title: title, summary: summary, index: entityIndex)
      let shares = try cells[19].decode(Int.self)
      let recommendations = try cells[20].decode(Int.self)
      guard analysis.eligible, analysis.materiality != "routine-chatter" || shares>=3 || recommendations>=1 else { continue }
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
        topicKeys: analysis.sportIDs + analysis.competitionIDs,publishedAt: story.publishedAt,
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
    let baseline = try WireRanker.rank(candidates: wireCandidates, asOf: asOf, config: SportsCandidateQuality.ranking)
    let candidates = baseline.items.enumerated().compactMap { index, scored -> SportsRankCandidate? in
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
          UPDATE sports_generations SET is_active = FALSE WHERE language = \(language) AND is_active = TRUE
          """, logger: self.logger)
      }
      try await connection.query("""
        INSERT INTO sports_generations
          (generation_id, source_generation_id, language, algorithm_version, generated_at, expires_at, payload, is_active)
        VALUES (\(generationID), \(sourceID), \(language), 'sports-v1', \(asOf),
          \(asOf.addingTimeInterval(48 * 3600)), \(payload)::jsonb, \(activate))
        """, logger: self.logger)
      try await connection.query("""
        DELETE FROM sports_generations WHERE generation_id IN (
          SELECT generation_id FROM sports_generations WHERE expires_at <= \(asOf)
          ORDER BY expires_at LIMIT 100)
        """, logger: self.logger)
      try await connection.query("""
        DELETE FROM sports_catalog_snapshots WHERE snapshot_id IN (
          SELECT snapshot_id FROM sports_catalog_snapshots
          WHERE is_active = FALSE AND generated_at < \(asOf.addingTimeInterval(-7 * 86_400))
          ORDER BY generated_at LIMIT 20)
        """, logger: self.logger)
    }
    logger.info("Sports generation committed", metadata: ["language": .string(language),
      "candidates": .stringConvertible(candidates.count), "activated": .stringConvertible(activate)])
  }
}
