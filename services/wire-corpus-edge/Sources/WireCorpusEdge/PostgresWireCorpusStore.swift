import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresWireCorpusStore: WireCorpusStoring {
  private struct Generation: Sendable {
    let id: UUID
    let language: String
    let generatedAt: Date
    let expiresAt: Date
    let recovering: Bool
  }

  private let pool: PostgresClient
  private let logger: Logger
  private let payloadCache: WireCorpusPayloadCache?

  init(pool: PostgresClient, logger: Logger, payloadCache: WireCorpusPayloadCache? = nil) {
    self.pool = pool
    self.logger = logger
    self.payloadCache = payloadCache
  }

  func ping() async throws {
    let rows = try await pool.query(
      "SELECT contract_version FROM wire_serving.contract LIMIT 1",
      logger: logger
    )
    for try await row in rows {
      guard try row.decode(Int.self) == 3 else {
        throw WireCorpusEdgeStoreError.contractMismatch
      }
      return
    }
    throw WireCorpusEdgeStoreError.contractMismatch
  }

  func requireFreshBaseline(now: Date) async throws {
    let rows = try await pool.query(
      "SELECT has_current_snapshot, oldest_successful_at FROM wire_serving.label_health",
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((Bool?, Date?).self)
      guard value.0 == true, let oldest = value.1,
        oldest >= now.addingTimeInterval(-30 * 60)
      else {
        throw WireCorpusEdgeStoreError.moderationUnavailable
      }
      return
    }
    throw WireCorpusEdgeStoreError.moderationUnavailable
  }

  func circleCandidates(
    actorHashes: [String],
    language: String,
    since: Date,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusCandidateResponse {
    try await requireFreshBaseline(now: now)
    let generation = try await activeGeneration(language: language, now: now)
    let rows = try await pool.query(
      """
      WITH matched AS MATERIALIZED (
        SELECT *
        FROM wire_serving.circle_signal_facts
        WHERE actor_key_hash = ANY(\(actorHashes))
          AND occurred_at >= \(since)
          AND (\(language) = 'und' OR language_code = \(language))
      ), selected AS (
        SELECT canonical_key, COUNT(DISTINCT actor_key_hash) AS participant_count,
               MAX(occurred_at) AS latest_signal
        FROM matched
        GROUP BY canonical_key
        ORDER BY participant_count DESC, latest_signal DESC, canonical_key
        LIMIT \(limit)
      )
      SELECT matched.canonical_key, canonical_url, representative_uri, title, summary,
             published_at, thumbnail_url, source_name, source_domain, publication_id,
             author_name, provenance::text, author_key, publication_key,
             publication_homepage_url, publication_icon_url, topic_keys::text,
             actor_key_hash, signal_kind,
             source_collection, source_action, source_uri, occurred_at
      FROM matched
      JOIN selected USING (canonical_key)
      ORDER BY selected.participant_count DESC, selected.latest_signal DESC,
               matched.canonical_key, matched.occurred_at DESC, matched.actor_key_hash
      """,
      logger: logger
    )
    let decoder = JSONDecoder()
    var storyOrder: [String] = []
    var items: [String: WireFeedItem] = [:]
    var topics: [String: [String]] = [:]
    var facts: [String: [WireCorpusSignalFact]] = [:]
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let canonicalKey = try cells[0].decode(String.self)
      if items[canonicalKey] == nil {
        storyOrder.append(canonicalKey)
        let provenanceJSON = try cells[11].decode(String.self)
        items[canonicalKey] = WireFeedItem(
          itemID: canonicalKey,
          canonicalURL: try cells[1].decode(String.self),
          representativeURI: try cells[2].decode(String?.self),
          title: try cells[3].decode(String.self),
          summary: try cells[4].decode(String?.self),
          publishedAt: try cells[5].decode(Date?.self),
          thumbnailURL: try cells[6].decode(String?.self),
          source: WireItemSource(
            name: try cells[7].decode(String.self),
            domain: try cells[8].decode(String.self),
            publication: try cells[9].decode(String?.self),
            author: try cells[10].decode(String?.self),
            publicationKey: try cells[13].decode(String?.self),
            homepageURL: try cells[14].decode(String?.self),
            iconURL: try cells[15].decode(String?.self)
          ),
          reasons: [],
          provenance: (try? decoder.decode(
            [WireProvenanceKind].self,
            from: Data(provenanceJSON.utf8)
          )) ?? []
        )
        let topicsJSON = try cells[16].decode(String.self)
        topics[canonicalKey] = (try? decoder.decode(
          [String].self,
          from: Data(topicsJSON.utf8)
        )) ?? []
      }
      guard let kind = WireSignalKind(rawValue: try cells[18].decode(String.self)) else {
        throw WireCorpusEdgeStoreError.contractMismatch
      }
      facts[canonicalKey, default: []].append(
        WireCorpusSignalFact(
          actorHash: try cells[17].decode(String.self),
          kind: kind,
          sourceCollection: try cells[19].decode(String.self),
          sourceAction: try cells[20].decode(String.self),
          sourceURI: try cells[21].decode(String.self),
          occurredAt: try cells[22].decode(Date.self)
        )
      )
    }
    let stories = storyOrder.compactMap { key -> WireCorpusCandidateStory? in
      guard let item = items[key] else { return nil }
      return WireCorpusCandidateStory(
        item: item,
        topicKeys: topics[key] ?? [],
        facts: facts[key] ?? []
      )
    }
    return WireCorpusCandidateResponse(
      generationID: generation?.id.uuidString.lowercased()
        ?? "circle-\(Int(now.timeIntervalSince1970 / 300))",
      generatedAt: now,
      language: language,
      stories: stories,
      exhausted: stories.count < limit
    )
  }

  func feed(
    language: String,
    generationID: UUID?,
    startOrdinal: Int,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusPage {
    try await requireFreshBaseline(now: now)
    let generation: Generation
    if let generationID {
      guard let retained = try await retainedGeneration(id: generationID, now: now),
        retained.language == language
      else {
        throw WireCorpusEdgeStoreError.cursorExpired
      }
      generation = retained
    } else if let active = try await activeGeneration(language: language, now: now) {
      generation = active
    } else {
      return try await fallback(language: language, limit: limit, now: now)
    }

    let rows = try await cachedRankedRows(
      generationID: generation.id,
      startOrdinal: startOrdinal,
      limit: limit, language: generation.language, now: now, expiresAt: generation.expiresAt
    )
    let age = now.timeIntervalSince(generation.generatedAt)
    return WireCorpusPage(
      generationID: generation.id.uuidString.lowercased(),
      generatedAt: generation.generatedAt,
      language: generation.language,
      source: age > 10 * 60 ? .staleGeneration : .ranked,
      degraded: generation.recovering || age > 10 * 60,
      rows: rows,
      exhausted: rows.count < limit
    )
  }

  func edition(language: String, region: WireViewerRegion?, now: Date) async throws -> WireEdition {
    try await requireFreshBaseline(now: now)
    guard let generation = try await activeGeneration(language: language, now: now) else {
      return try await fallbackEdition(language: language, now: now)
    }
    let result: WireEdition
    if let payloadCache {
      let revision = try await editionRevision(generationID: generation.id)
      result = try await payloadCache.value(
        CachedEdition.self,
        scope: ["edition", generation.id.uuidString, language, region?.rawValue ?? "default"],
        revision: revision, now: now,
        lifetime: WireCorpusPayloadCache.generationLifetime(expiresAt: generation.expiresAt, now: now),
        currentRevision: { try await self.editionRevision(generationID: generation.id) },
        validatesMembership: { $0.proof.matches(revision: revision, region: region) },
        load: { try await self.loadEdition(generation: generation, region: region, now: now) }).value
    } else {
      result = try await loadEdition(generation: generation, region: region, now: now).value
    }
    let stale = now.timeIntervalSince(generation.generatedAt) > 10 * 60
    return WireEdition(
      algorithmVersion: result.algorithmVersion, generationID: result.generationID,
      generatedAt: result.generatedAt, language: result.language, cursor: result.cursor,
      source: stale ? .staleGeneration : .ranked, degraded: generation.recovering || stale,
      leadStories: result.leadStories, publicationPanels: result.publicationPanels,
      storyRails: result.storyRails, generalStories: result.generalStories,
      trendingStories: result.trendingStories, talkedAboutAccounts: result.talkedAboutAccounts)
  }

  private struct CachedEdition: Codable, Sendable {
    let value: WireEdition
    let proof: WireEditionCacheProof
  }

  private func loadEdition(generation: Generation, region: WireViewerRegion?, now: Date) async throws -> CachedEdition {
    let generationRows = try await pool.query(
      """
      SELECT algorithm_version, continuation_ordinal
      FROM wire_serving.edition_generations
      WHERE generation_id = \(generation.id)
      LIMIT 1
      """,
      logger: logger
    )
    var algorithmVersion: String?
    var continuationOrdinal = 0
    for try await row in generationRows {
      let value = try row.decode((String, Int).self)
      algorithmVersion = value.0
      continuationOrdinal = value.1
    }
    guard let algorithmVersion else { throw WireCorpusEdgeStoreError.contractMismatch }

    var modulePrefix = ""
    if region == .outsideUnitedStates {
      let prefix = "\(WireViewerRegion.outsideUnitedStates.rawValue):"
      let variantRows = try await pool.query(
        """
        SELECT EXISTS(
          SELECT 1 FROM wire_serving.edition_modules
          WHERE generation_id = \(generation.id) AND module_key LIKE \("\(prefix)%")
        )
        """,
        logger: logger
      )
      for try await row in variantRows {
        if try row.decode(Bool.self) { modulePrefix = prefix }
      }
    }
    let modulePattern = "\(modulePrefix)%"

    let itemRows = try await pool.query(
      """
      SELECT module_key, module_position, canonical_key, canonical_url, representative_uri,
             title, summary, published_at, thumbnail_url, source_name, source_domain,
             publication_id, author_name, provenance::text, author_key, reason_codes::text,
             publication_key, publication_homepage_url, publication_icon_url
      FROM wire_serving.edition_module_items
      WHERE generation_id = \(generation.id)
        AND (\(modulePrefix) = '' AND POSITION(':' IN module_key) = 0
          OR \(modulePrefix) <> '' AND module_key LIKE \(modulePattern))
      ORDER BY module_key, module_position
      """,
      logger: logger
    )
    var itemsByModule: [String: [WireFeedItem]] = [:]
    for try await row in itemRows {
      let cells = row.makeRandomAccess()
      let key = try cells[0].decode(String.self)
      itemsByModule[key, default: []].append(
        try Self.decodeItem(
          row: row,
          offset: 2,
          reasonsJSON: try cells[15].decode(String.self),
          metadataOffset: 16
        )
      )
    }

    let moduleRows = try await pool.query(
      """
      SELECT module_key, module_kind, title, position, reason_code,
             publication_key, publication_name, publication_domain,
             publication_homepage_url, publication_icon_url
      FROM wire_serving.edition_modules
      WHERE generation_id = \(generation.id)
        AND (\(modulePrefix) = '' AND POSITION(':' IN module_key) = 0
          OR \(modulePrefix) <> '' AND module_key LIKE \(modulePattern))
      ORDER BY position
      """,
      logger: logger
    )
    var rawModuleKeys: [String] = []
    var leads: [WireFeedItem] = []
    var panels: [WireEditionPublicationPanel] = []
    var rails: [WireEditionStoryRail] = []
    var general: [WireFeedItem] = []
    var trending: [WireFeedItem] = []
    for try await row in moduleRows {
      let value = try row.decode(
        (String, String, String?, Int, String?, String?, String?, String?, String?, String?).self
      )
      rawModuleKeys.append(value.0)
      let stories = itemsByModule[value.0] ?? []
      let publicModuleKey = modulePrefix.isEmpty
        ? value.0
        : String(value.0.dropFirst(modulePrefix.count))
      switch value.1 {
      case "top_stories":
        leads = stories
      case "publication_spotlight":
        guard let key = value.5, let name = value.6, let domain = value.7 else {
          throw WireCorpusEdgeStoreError.contractMismatch
        }
        panels.append(
          WireEditionPublicationPanel(
            publication: WireEditionPublication(
              key: key,
              id: stories.first?.source.publication,
              name: name,
              domain: domain,
              homepageURL: value.8,
              iconURL: value.9
            ),
            stories: stories
          )
        )
      case "story_rail":
        guard let reasonValue = value.4,
          let reason = WireReasonCode(rawValue: reasonValue),
          let title = value.2
        else { throw WireCorpusEdgeStoreError.contractMismatch }
        rails.append(WireEditionStoryRail(
          id: publicModuleKey, title: title, reason: reason, stories: stories
        ))
      case "general":
        general = stories
      case "trending":
        trending = stories
      default:
        throw WireCorpusEdgeStoreError.contractMismatch
      }
    }

    let moreRows = try await pool.query(
      """
      SELECT EXISTS(
        SELECT 1 FROM wire_serving.ranked_items
        WHERE generation_id = \(generation.id) AND position >= \(continuationOrdinal)
      )
      """,
      logger: logger
    )
    var hasMore = false
    for try await row in moreRows { hasMore = try row.decode(Bool.self) }
    let accounts = try await materializedTalkedAccounts(generationID: generation.id)
    let age = now.timeIntervalSince(generation.generatedAt)
    let value = WireEdition(
      algorithmVersion: algorithmVersion,
      generationID: generation.id.uuidString.lowercased(),
      generatedAt: generation.generatedAt,
      language: generation.language,
      cursor: hasMore ? String(continuationOrdinal) : nil,
      source: age > 10 * 60 ? .staleGeneration : .ranked,
      degraded: generation.recovering || age > 10 * 60,
      leadStories: leads,
      publicationPanels: panels,
      storyRails: rails,
      generalStories: general,
      trendingStories: trending,
      talkedAboutAccounts: accounts.count >= 4 ? accounts : []
    )
    return CachedEdition(value: value, proof: WireEditionCacheProof(
      modulePrefix: modulePrefix, moduleKeys: rawModuleKeys,
      stories: itemsByModule.flatMap { key, items in items.map { [key, $0.itemID] } },
      accounts: accounts.map(\.did), hasMore: hasMore))
  }

  func item(id: String, now: Date) async throws -> WireCorpusItem? {
    try await requireFreshBaseline(now: now)
    guard let payloadCache else { return try await loadItem(id: id) }
    let revision = try await itemRevision(id: id)
    guard !revision.isEmpty else { return nil }
    return try await payloadCache.value(
      WireCorpusItem?.self, scope: ["item", id], revision: revision, now: now,
      currentRevision: { try await self.itemRevision(id: id) },
      validatesMembership: { $0?.item.itemID == id },
      load: { try await self.loadItem(id: id) })
  }

  private func loadItem(id: String) async throws -> WireCorpusItem? {
    let rows = try await pool.query(
      """
      SELECT canonical_key, canonical_url, representative_uri, title, summary, published_at,
             thumbnail_url, source_name, source_domain, publication_id, author_name,
             provenance::text, author_key, publication_key,
             publication_homepage_url, publication_icon_url
      FROM wire_serving.items
      WHERE canonical_key = \(id)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return WireCorpusItem(
        item: try Self.decodeItem(row: row, reasonsJSON: "[]", metadataOffset: 13),
        sourceActorKey: try row.makeRandomAccess()[12].decode(String?.self)
      )
    }
    return nil
  }

  private struct CatalogSnapshot: Codable, Sendable {
    let value: WireCorpusCatalog
    let expiresAt: Date
  }

  func catalog(now: Date) async throws -> WireCorpusCatalog {
    try await requireFreshBaseline(now: now)
    guard let payloadCache else { return try await loadCatalog(now: now).value }
    // Catalog is advisory, contains no item payloads, and may lag publication by
    // five seconds. Feed/edition generation selection and all moderation remain live.
    let snapshot = try await payloadCache.value(
      CatalogSnapshot.self, scope: ["catalog"], revision: "advisory-v1", now: now, lifetime: 5,
      currentRevision: { "advisory-v1" }, load: { try await self.loadCatalog(now: now) })
    guard snapshot.expiresAt > now else { return try await loadCatalog(now: now).value }
    return snapshot.value
  }

  private func loadCatalog(now: Date) async throws -> CatalogSnapshot {
    let generations = try await acceptableGenerations(now: now)
    let latest = generations.max { $0.generatedAt < $1.generatedAt }
    let fallbackAvailable = latest == nil ? try await hasFallbackCorpus() : false
    return CatalogSnapshot(
      value: WireCorpusCatalog(
        available: latest != nil || fallbackAvailable,
        supportedLanguages: generations.map(\.language).filter { $0 != "und" }.sorted(),
        latestGenerationID: latest?.id.uuidString.lowercased(), generatedAt: latest?.generatedAt),
      expiresAt: generations.map(\.expiresAt).min() ?? now.addingTimeInterval(5))
  }

  private func activeGeneration(language: String, now: Date) async throws -> Generation? {
    try await activeGeneration(exactLanguage: language, now: now)
  }

  private func activeGeneration(exactLanguage language: String, now: Date) async throws -> Generation? {
    let rows = try await pool.query(
      """
      SELECT generation_id, language_bucket, generated_at, expires_at, recovering
      FROM wire_serving.feed_state
      WHERE language_bucket = \(language) AND expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date, Bool).self)
      return Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3,
        recovering: value.4)
    }
    return nil
  }

  private func retainedGeneration(id: UUID, now: Date) async throws -> Generation? {
    let rows = try await pool.query(
      """
      SELECT generation_id, language_bucket, generated_at, expires_at, recovering
      FROM wire_serving.generations
      WHERE generation_id = \(id) AND expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date, Bool).self)
      return Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3,
        recovering: value.4)
    }
    return nil
  }

  private func acceptableGenerations(now: Date) async throws -> [Generation] {
    let rows = try await pool.query(
      """
      SELECT generation_id, language_bucket, generated_at, expires_at, recovering
      FROM wire_serving.feed_state
      WHERE expires_at > \(now)
      """,
      logger: logger
    )
    var result: [Generation] = []
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date, Bool).self)
      result.append(Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3,
        recovering: value.4))
    }
    return result
  }

  private func cachedRankedRows(
    generationID: UUID, startOrdinal: Int, limit: Int, language: String, now: Date, expiresAt: Date
  ) async throws -> [WireCorpusRow] {
    guard let payloadCache else {
      return try await rankedRows(generationID: generationID, startOrdinal: startOrdinal, limit: limit)
    }
    let revision = try await rankedRevision(generationID: generationID, startOrdinal: startOrdinal, limit: limit)
    let expectedKeys = Self.revisionIdentities(revision, index: 1)
    return try await payloadCache.value(
      [WireCorpusRow].self,
      scope: ["feed", generationID.uuidString, language, String(startOrdinal), String(limit)],
      revision: revision, now: now, lifetime: WireCorpusPayloadCache.generationLifetime(expiresAt: expiresAt, now: now),
      currentRevision: {
        try await self.rankedRevision(generationID: generationID, startOrdinal: startOrdinal, limit: limit)
      }, validatesMembership: { rows in
        rows.count == expectedKeys.count && rows.allSatisfy { expectedKeys.contains($0.item.itemID) }
      }, load: {
        try await self.rankedRows(generationID: generationID, startOrdinal: startOrdinal, limit: limit)
      })
  }

  private func rankedRevision(generationID: UUID, startOrdinal: Int, limit: Int) async throws -> String {
    try await revisionRows("""
      SELECT json_build_array(position, canonical_key, cache_revision)::text
      FROM wire_serving.ranked_items
      WHERE generation_id = \(generationID) AND position >= \(startOrdinal)
      ORDER BY position LIMIT \(limit)
      """)
  }

  private func itemRevision(id: String) async throws -> String {
    try await revisionRows("""
      SELECT json_build_array(canonical_key, cache_revision)::text
      FROM wire_serving.items WHERE canonical_key = \(id) LIMIT 1
      """)
  }

  private func editionRevision(generationID: UUID) async throws -> String {
    // One bounded result set covers all variant membership, module presentation,
    // continuation eligibility and profile expiry; no per-item database round trips.
    try await revisionRows("""
      SELECT token FROM (
        SELECT 'generation' AS kind, '' AS ordering,
          json_build_array('generation', cache_revision, continuation_ordinal)::text AS token
        FROM wire_serving.edition_generations WHERE generation_id = \(generationID)
        UNION ALL
        SELECT 'module', module_key, json_build_array('module', module_key, cache_revision)::text
        FROM wire_serving.edition_modules WHERE generation_id = \(generationID)
        UNION ALL
        SELECT 'item', module_key || ':' || module_position::text,
          json_build_array('item', module_key, module_position, canonical_key, cache_revision)::text
        FROM wire_serving.edition_module_items WHERE generation_id = \(generationID)
        UNION ALL
        SELECT 'account', position::text,
          json_build_array('account', position, subject_did, cache_revision)::text
        FROM wire_serving.edition_talked_accounts WHERE generation_id = \(generationID)
        UNION ALL
        SELECT 'continuation', '', json_build_array('continuation', EXISTS(
          SELECT 1 FROM wire_serving.ranked_items AS ranked
          JOIN wire_serving.edition_generations AS edition USING (generation_id)
          WHERE ranked.generation_id = \(generationID) AND ranked.position >= edition.continuation_ordinal
        ))::text
      ) AS revisions ORDER BY kind, ordering, token
      """)
  }

  private static func revisionIdentities(_ revision: String, kind: String? = nil, index: Int) -> Set<String> {
    Set(revision.split(separator: "\n").compactMap { token in
      guard let fields = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [Any],
        fields.count > index, kind == nil || fields.first as? String == kind
      else { return nil }
      return fields[index] as? String
    })
  }

  private func revisionRows(_ query: PostgresQuery) async throws -> String {
    let rows = try await pool.query(query, logger: logger)
    var tokens: [String] = []
    for try await row in rows { tokens.append(try row.decode(String.self)) }
    // JSON arrays encode boundaries unambiguously, including keys containing separators.
    return tokens.joined(separator: "\n")
  }

  private func rankedRows(
    generationID: UUID,
    startOrdinal: Int,
    limit: Int
  ) async throws -> [WireCorpusRow] {
    let rows = try await pool.query(
      """
      SELECT position, canonical_key, canonical_url, representative_uri, title, summary,
             published_at, thumbnail_url, source_name, source_domain, publication_id,
             author_name, provenance::text, author_key, reason_codes::text,
             publication_key, publication_homepage_url, publication_icon_url
      FROM wire_serving.ranked_items
      WHERE generation_id = \(generationID) AND position >= \(startOrdinal)
      ORDER BY position
      LIMIT \(limit)
      """,
      logger: logger
    )
    var result: [WireCorpusRow] = []
    for try await row in rows {
      let cells = row.makeRandomAccess()
      result.append(
        WireCorpusRow(
          ordinal: try cells[0].decode(Int.self),
          item: try Self.decodeItem(
            row: row,
            offset: 1,
            reasonsJSON: try cells[14].decode(String.self),
            metadataOffset: 15
          ),
          sourceActorKey: try cells[13].decode(String?.self)
        )
      )
    }
    return result
  }

  private func hasFallbackCorpus() async throws -> Bool {
    let rows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM (SELECT 1 FROM wire_serving.fallback_items LIMIT \(WireDataPolicy.minimumGlobalCandidates)) AS bounded",
      logger: logger
    )
    for try await row in rows {
      return try row.decode(Int64.self) >= Int64(WireDataPolicy.minimumGlobalCandidates)
    }
    return false
  }

  private func fallback(language: String, limit: Int, now: Date) async throws -> WireCorpusPage {
    let rows = try await pool.query(
      """
      SELECT canonical_key, canonical_url, representative_uri, title, summary, published_at,
             thumbnail_url, source_name, source_domain, publication_id, author_name,
             provenance::text, author_key, topic_keys::text, first_seen_at,
             publication_key, publication_homepage_url, publication_icon_url
      FROM wire_serving.fallback_items
      WHERE (\(language) = 'und' OR language_code = \(language))
      ORDER BY (provenance ? 'standard_site') DESC,
               COALESCE(published_at, first_seen_at) DESC, canonical_key
      LIMIT 5000
      """,
      logger: logger
    )
    var itemsByKey: [String: (WireFeedItem, String?)] = [:]
    var candidates: [WireScoredCandidate] = []
    var ordinal = 0
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let item = try Self.decodeItem(row: row, reasonsJSON: "[]", metadataOffset: 15)
      let publication = try cells[9].decode(String?.self)
      let author = try cells[12].decode(String?.self)
      let topicsJSON = try cells[13].decode(String.self)
      let firstSeenAt = try cells[14].decode(Date.self)
      let topics = (try? JSONDecoder().decode([String].self, from: Data(topicsJSON.utf8))) ?? []
      itemsByKey[item.itemID] = (item, author)
      candidates.append(
        WireScoredCandidate(
          candidate: WireCandidate(
            canonicalKey: item.itemID,
            canonicalURL: item.canonicalURL,
            representativeURI: item.representativeURI,
            sourceDomain: item.source.domain,
            publicationID: publication,
            authorKey: author,
            topicKeys: topics,
            publishedAt: item.publishedAt,
            firstSeenAt: firstSeenAt
          ),
          score: Double(5_000 - ordinal),
          reasonCodes: []
        )
      )
      ordinal += 1
    }
    let reranked = WireDiversityReranker.rerank(candidates, policy: WireDiversityPolicy())
    let selected = reranked.items.prefix(limit)
    let resultRows = selected.enumerated().compactMap { index, candidate -> WireCorpusRow? in
      guard let stored = itemsByKey[candidate.candidate.canonicalKey] else { return nil }
      return WireCorpusRow(ordinal: index, item: stored.0, sourceActorKey: stored.1)
    }
    let bucket = Int(now.timeIntervalSince1970 / 300)
    return WireCorpusPage(
      generationID: "fallback-\(bucket)",
      generatedAt: Date(timeIntervalSince1970: Double(bucket * 300)),
      language: language,
      source: .simplifiedFallback,
      degraded: true,
      rows: resultRows,
      exhausted: true
    )
  }

  private static func decodeItem(
    row: PostgresRow,
    offset: Int = 0,
    reasonsJSON: String,
    metadataOffset: Int? = nil
  ) throws -> WireFeedItem {
    let cells = row.makeRandomAccess()
    let decoder = JSONDecoder()
    let provenanceJSON = try cells[offset + 11].decode(String.self)
    return WireFeedItem(
      itemID: try cells[offset].decode(String.self),
      canonicalURL: try cells[offset + 1].decode(String.self),
      representativeURI: try cells[offset + 2].decode(String?.self),
      title: try cells[offset + 3].decode(String.self),
      summary: try cells[offset + 4].decode(String?.self),
      publishedAt: try cells[offset + 5].decode(Date?.self),
      thumbnailURL: try cells[offset + 6].decode(String?.self),
      source: WireItemSource(
        name: try cells[offset + 7].decode(String.self),
        domain: try cells[offset + 8].decode(String.self),
        publication: try cells[offset + 9].decode(String?.self),
        author: try cells[offset + 10].decode(String?.self),
        publicationKey: try metadataOffset.map { try cells[$0].decode(String?.self) } ?? nil,
        homepageURL: try metadataOffset.map { try cells[$0 + 1].decode(String?.self) } ?? nil,
        iconURL: try metadataOffset.map { try cells[$0 + 2].decode(String?.self) } ?? nil
      ),
      reasons: (try? decoder.decode([WireReasonCode].self, from: Data(reasonsJSON.utf8))) ?? [],
      provenance: (try? decoder.decode([WireProvenanceKind].self, from: Data(provenanceJSON.utf8))) ?? []
    )
  }

  private func materializedTalkedAccounts(
    generationID: UUID
  ) async throws -> [WireTalkedAboutAccount] {
    let rows = try await pool.query(
      """
      SELECT position, subject_did, handle, display_name, avatar_url, description
      FROM wire_serving.edition_talked_accounts
      WHERE generation_id = \(generationID)
      ORDER BY position
      LIMIT 10
      """,
      logger: logger
    )
    var result: [WireTalkedAboutAccount] = []
    for try await row in rows {
      let value = try row.decode((Int, String, String?, String?, String?, String?).self)
      result.append(
        WireTalkedAboutAccount(
          did: value.1,
          handle: value.2,
          displayName: value.3,
          avatarURL: value.4,
          description: value.5
        )
      )
    }
    return result
  }

  private func fallbackEdition(language: String, now: Date) async throws -> WireEdition {
    let page = try await fallback(language: language, limit: 50, now: now)
    let edition = WireEditionAssembler.assemble(
      generationID: page.generationID,
      generatedAt: page.generatedAt,
      language: page.language,
      source: page.source,
      degraded: page.degraded,
      rankedItems: page.rows.map(\.item)
    )
    let accounts = try await latestMaterializedTalkedAccounts(language: page.language)
    guard accounts.count >= 4 else { return edition }
    return WireEdition(
      algorithmVersion: edition.algorithmVersion,
      generationID: edition.generationID,
      generatedAt: edition.generatedAt,
      language: edition.language,
      cursor: edition.cursor,
      source: edition.source,
      degraded: edition.degraded,
      leadStories: edition.leadStories,
      publicationPanels: edition.publicationPanels,
      storyRails: edition.storyRails,
      generalStories: edition.generalStories,
      trendingStories: edition.trendingStories,
      talkedAboutAccounts: accounts
    )
  }

  private func latestMaterializedTalkedAccounts(
    language: String
  ) async throws -> [WireTalkedAboutAccount] {
    let rows = try await pool.query(
      """
      SELECT generation.generation_id
      FROM wire_serving.edition_generations generation
      WHERE generation.language_bucket = \(language)
        AND EXISTS (
          SELECT 1 FROM wire_serving.edition_talked_accounts account
          WHERE account.generation_id = generation.generation_id
        )
      ORDER BY generation.generated_at DESC, generation.generation_id DESC
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try await materializedTalkedAccounts(generationID: row.decode(UUID.self))
    }
    return []
  }
}
