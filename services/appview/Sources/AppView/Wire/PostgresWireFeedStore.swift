import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresWireFeedStore: WireFeedStore {
  private struct Generation: Sendable {
    let id: UUID
    let language: String
    let generatedAt: Date
    let expiresAt: Date
  }

  private let pool: PostgresClient
  private let logger: Logger
  private let cursorCodec: WireCursorCodec
  private let mode: WireDiscoveryMode
  private let moderationCache: WireViewerModerationCache

  init(
    pool: PostgresClient,
    logger: Logger,
    cursorSecret: String,
    mode: WireDiscoveryMode,
    moderationCache: WireViewerModerationCache
  ) throws {
    self.pool = pool
    self.logger = logger
    self.cursorCodec = try WireCursorCodec(secret: cursorSecret)
    self.mode = mode
    self.moderationCache = moderationCache
  }

  func getFeed(
    cursor: String?,
    limit: Int,
    language: String?,
    viewerDid: String?,
    now: Date
  ) async throws -> WirePage {
    guard mode.servesAPI else { throw WireServingError.unavailable }
    try await requireUsableBaselineLabels(now: now)
    let safeLimit = max(1, min(limit, 50))
    let requestedLanguage = Self.primaryLanguage(language)
    let generation: Generation
    let startOrdinal: Int

    if let cursor {
      let decoded: WireCursor
      do {
        decoded = try cursorCodec.decode(cursor)
      } catch {
        throw WireServingError.invalidCursor
      }
      guard decoded.language == requestedLanguage || decoded.language == "und" else {
        throw WireServingError.invalidCursor
      }
      guard let generationID = UUID(uuidString: decoded.generationID),
        let retained = try await retainedGeneration(id: generationID, now: now)
      else {
        throw WireServingError.cursorExpired
      }
      generation = retained
      startOrdinal = decoded.nextOrdinal
    } else if let active = try await activeGeneration(language: requestedLanguage) {
      generation = active
      startOrdinal = 0
    } else {
      return try await simplifiedFallback(
        limit: safeLimit,
        language: requestedLanguage,
        viewerDID: viewerDid,
        now: now
      )
    }

    let age = now.timeIntervalSince(generation.generatedAt)
    let moderation = try await moderationSnapshot(viewerDID: viewerDid, now: now)
    var accepted: [RankedRow] = []
    var scanOrdinal = startOrdinal
    var exhausted = false
    var scanned = 0
    while accepted.count <= safeLimit, !exhausted, scanned < 5_000 {
      let rows = try await rankedItems(
        generationID: generation.id,
        startOrdinal: scanOrdinal,
        limit: 500,
        now: now
      )
      exhausted = rows.count < 500
      scanned += rows.count
      if let last = rows.last { scanOrdinal = last.position + 1 }
      accepted.append(contentsOf: rows.filter { row in
        moderation?.allows(
          item: row.sourceActorKey ?? row.item.itemID,
          title: row.item.title,
          summary: row.item.summary,
          representativeURI: row.item.representativeURI
        ) ?? true
      })
      if rows.isEmpty { exhausted = true }
    }
    let pageItems = Array(accepted.prefix(safeLimit).map(\.item))
    let nextCursor: String?
    if accepted.count > safeLimit, let last = accepted.prefix(safeLimit).last {
      nextCursor = try cursorCodec.encode(
        WireCursor(
          generationID: generation.id.uuidString.lowercased(),
          language: generation.language,
          nextOrdinal: last.position + 1
        )
      )
    } else if !exhausted {
      nextCursor = try cursorCodec.encode(
        WireCursor(
          generationID: generation.id.uuidString.lowercased(),
          language: generation.language,
          nextOrdinal: scanOrdinal
        )
      )
    } else {
      nextCursor = nil
    }

    return WirePage(
      generationID: generation.id.uuidString.lowercased(),
      generatedAt: generation.generatedAt,
      language: generation.language,
      cursor: nextCursor,
      source: age > 10 * 60 ? .staleGeneration : .ranked,
      degraded: age > 10 * 60,
      items: pageItems
    )
  }

  func getEdition(
    language: String?,
    viewerDid: String?,
    now: Date
  ) async throws -> WireEdition {
    guard mode.servesAPI else { throw WireServingError.unavailable }
    try await requireUsableBaselineLabels(now: now)
    let requestedLanguage = Self.primaryLanguage(language)
    guard let generation = try await activeGeneration(language: requestedLanguage) else {
      let page = try await getFeed(
        cursor: nil,
        limit: 50,
        language: requestedLanguage,
        viewerDid: viewerDid,
        now: now
      )
      let edition = WireEditionAssembler.assemble(
        generationID: page.generationID,
        generatedAt: page.generatedAt,
        language: page.language,
        cursor: page.cursor,
        source: page.source,
        degraded: page.degraded,
        rankedItems: page.items
      )
      let accounts = try await latestMaterializedTalkedAccounts(
        language: page.language,
        viewerDID: viewerDid,
        now: now
      )
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

    let generationRows = try await pool.query(
      """
      SELECT algorithm_version, continuation_ordinal
      FROM wire_edition_generations
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
    guard let algorithmVersion else { throw WireServingError.unavailable }

    let itemRows = try await pool.query(
      """
      SELECT module.module_key, module.position, item.canonical_key, item.canonical_url,
             item.representative_uri, item.title, item.summary, item.published_at,
             item.thumbnail_url, item.source_name, item.source_domain, item.publication_id,
             item.author_name, item.provenance::text, item.author_key,
             ranked.reason_codes::text,
             COALESCE(NULLIF(item.publication_id, ''), item.source_domain),
             item.publication_homepage_url, item.publication_icon_url
      FROM wire_edition_module_items module
      JOIN wire_ranked_items ranked
        ON ranked.generation_id = module.generation_id
       AND ranked.canonical_key = module.canonical_key
      JOIN wire_items item ON item.canonical_key = module.canonical_key
      WHERE module.generation_id = \(generation.id)
        AND item.eligible = TRUE AND item.expires_at > \(now)
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels label
          WHERE label.canonical_key = item.canonical_key AND label.expires_at > \(now)
            AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY module.module_key, module.position
      """,
      logger: logger
    )
    let moderation = try await moderationSnapshot(viewerDID: viewerDid, now: now)
    var itemsByModule: [String: [WireFeedItem]] = [:]
    for try await row in itemRows {
      let cells = row.makeRandomAccess()
      let key = try cells[0].decode(String.self)
      let item = try Self.decodeItem(
        row: row,
        offset: 2,
        reasonsJSON: try cells[15].decode(String.self),
        metadataOffset: 16
      )
      let actorKey = try cells[14].decode(String?.self)
      guard moderation?.allows(
        item: actorKey ?? item.itemID,
        title: item.title,
        summary: item.summary,
        representativeURI: item.representativeURI
      ) ?? true else { continue }
      itemsByModule[key, default: []].append(item)
    }

    let moduleRows = try await pool.query(
      """
      SELECT module_key, module_kind, title, position, reason_code,
             publication_key, publication_name, publication_domain,
             publication_homepage_url, publication_icon_url
      FROM wire_edition_modules
      WHERE generation_id = \(generation.id)
      ORDER BY position
      """,
      logger: logger
    )
    var leads: [WireFeedItem] = []
    var panels: [WireEditionPublicationPanel] = []
    var rails: [WireEditionStoryRail] = []
    var general: [WireFeedItem] = []
    var trending: [WireFeedItem] = []
    for try await row in moduleRows {
      let value = try row.decode(
        (String, String, String?, Int, String?, String?, String?, String?, String?, String?).self
      )
      let stories = itemsByModule[value.0] ?? []
      switch value.1 {
      case "top_stories":
        leads = stories
      case "publication_spotlight":
        guard stories.count >= WireEditionAssembler.minimumStoriesPerPublicationPanel,
          let key = value.5, let name = value.6, let domain = value.7
        else { continue }
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
        guard stories.count >= WireEditionAssembler.minimumStoriesPerRail,
          let reasonValue = value.4,
          let reason = WireReasonCode(rawValue: reasonValue),
          let title = value.2
        else { continue }
        rails.append(WireEditionStoryRail(id: value.0, title: title, reason: reason, stories: stories))
      case "general":
        general = stories
      case "trending":
        trending = stories
      default:
        throw WireServingError.unavailable
      }
    }

    let moreRows = try await pool.query(
      """
      SELECT EXISTS(
        SELECT 1 FROM wire_ranked_items
        WHERE generation_id = \(generation.id) AND position >= \(continuationOrdinal)
      )
      """,
      logger: logger
    )
    var hasMore = false
    for try await row in moreRows { hasMore = try row.decode(Bool.self) }
    let cursor = hasMore
      ? try cursorCodec.encode(
        WireCursor(
          generationID: generation.id.uuidString.lowercased(),
          language: generation.language,
          nextOrdinal: continuationOrdinal
        )
      )
      : nil
    let accounts = try await materializedTalkedAccounts(
      generationID: generation.id,
      viewerDID: viewerDid,
      now: now
    )
    let age = now.timeIntervalSince(generation.generatedAt)
    return WireEdition(
      algorithmVersion: algorithmVersion,
      generationID: generation.id.uuidString.lowercased(),
      generatedAt: generation.generatedAt,
      language: generation.language,
      cursor: cursor,
      source: age > 10 * 60 ? .staleGeneration : .ranked,
      degraded: age > 10 * 60,
      leadStories: leads,
      publicationPanels: panels,
      storyRails: rails,
      generalStories: general,
      trendingStories: trending,
      talkedAboutAccounts: accounts.count >= 4 ? accounts : []
    )
  }

  func getItem(itemId: String, viewerDid: String?) async throws -> WireItemDetail? {
    guard mode.servesAPI else { throw WireServingError.unavailable }
    try await requireUsableBaselineLabels(now: Date())
    let rows = try await pool.query(
      """
      SELECT canonical_key, canonical_url, representative_uri, title, summary, published_at,
             thumbnail_url, source_name, source_domain, publication_id, author_name,
             provenance::text, author_key,
             COALESCE(NULLIF(publication_id, ''), source_domain),
             publication_homepage_url, publication_icon_url
      FROM wire_items
      WHERE canonical_key = \(itemId) AND eligible = TRUE AND expires_at > NOW()
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels label
          WHERE label.canonical_key = wire_items.canonical_key AND label.expires_at > NOW()
            AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let item = try Self.decodeItem(row: row, reasonsJSON: "[]", metadataOffset: 13)
      let actorKey = try row.makeRandomAccess()[12].decode(String?.self)
      let moderation = try await moderationSnapshot(viewerDID: viewerDid, now: Date())
      guard moderation?.allows(
        item: actorKey ?? item.itemID,
        title: item.title,
        summary: item.summary,
        representativeURI: item.representativeURI
      ) ?? true else { return nil }
      return WireItemDetail(item: item, embedURL: item.canonicalURL)
    }
    return nil
  }

  func getCatalog(now: Date) async throws -> WireFeedCatalog {
    if mode.servesAPI { try await requireUsableBaselineLabels(now: now) }
    let generations = try await acceptableGenerations(now: now)
    let latest = generations.max { $0.generatedAt < $1.generatedAt }
    let fallbackAvailable = latest == nil ? try await hasFallbackCorpus(now: now) : false
    return WireFeedCatalog(
      enabled: mode.servesAPI,
      available: mode.isVisible && (latest != nil || fallbackAvailable),
      supportedLanguages: generations.map(\.language).filter { $0 != "und" }.sorted(),
      latestGenerationID: latest?.id.uuidString.lowercased(),
      generatedAt: latest?.generatedAt
    )
  }

  private func requireUsableBaselineLabels(now: Date) async throws {
    let rows = try await pool.query(
      """
      SELECT MIN(last_successful_at), COUNT(*)::bigint
      FROM wire_label_refresh_state
      WHERE is_current = TRUE
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((Date?, Int64).self)
      guard value.1 > 0, let oldestSuccess = value.0,
        oldestSuccess >= now.addingTimeInterval(-30 * 60)
      else { throw WireServingError.moderationUnavailable }
      return
    }
    throw WireServingError.moderationUnavailable
  }

  private func activeGeneration(language: String) async throws -> Generation? {
    if language != "und", let localized = try await activeGeneration(exactLanguage: language) {
      return localized
    }
    return try await activeGeneration(exactLanguage: "und")
  }

  private func activeGeneration(exactLanguage language: String) async throws -> Generation? {
    let rows = try await pool.query(
      """
      SELECT g.generation_id, g.language_bucket, g.generated_at, g.expires_at
      FROM wire_feed_state state
      JOIN wire_rank_generations g ON g.generation_id = state.active_generation_id
      WHERE state.feed_key = 'wire' AND state.language_bucket = \(language)
        AND g.status = 'committed'
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date).self)
      return Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3)
    }
    return nil
  }

  private func retainedGeneration(id: UUID, now: Date) async throws -> Generation? {
    let rows = try await pool.query(
      """
      SELECT generation_id, language_bucket, generated_at, expires_at
      FROM wire_rank_generations
      WHERE generation_id = \(id) AND status IN ('committed', 'superseded')
        AND expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date).self)
      return Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3)
    }
    return nil
  }

  private func acceptableGenerations(now: Date) async throws -> [Generation] {
    let rows = try await pool.query(
      """
      SELECT g.generation_id, g.language_bucket, g.generated_at, g.expires_at
      FROM wire_feed_state state
      JOIN wire_rank_generations g ON g.generation_id = state.active_generation_id
      WHERE state.feed_key = 'wire' AND g.status = 'committed'
        AND g.expires_at > \(now)
      """,
      logger: logger
    )
    var result: [Generation] = []
    for try await row in rows {
      let value = try row.decode((UUID, String, Date, Date).self)
      result.append(Generation(id: value.0, language: value.1, generatedAt: value.2, expiresAt: value.3))
    }
    return result
  }

  private struct RankedRow: Sendable {
    let position: Int
    let item: WireFeedItem
    let sourceActorKey: String?
  }

  private func rankedItems(
    generationID: UUID,
    startOrdinal: Int,
    limit: Int,
    now: Date
  ) async throws -> [RankedRow] {
    let rows = try await pool.query(
      """
      SELECT ranked.position, item.canonical_key, item.canonical_url, item.representative_uri,
             item.title, item.summary, item.published_at, item.thumbnail_url, item.source_name,
             item.source_domain, item.publication_id, item.author_name, item.provenance::text,
             item.author_key,
             ranked.reason_codes::text,
             COALESCE(NULLIF(item.publication_id, ''), item.source_domain),
             item.publication_homepage_url, item.publication_icon_url
      FROM wire_ranked_items ranked
      JOIN wire_items item ON item.canonical_key = ranked.canonical_key
      WHERE ranked.generation_id = \(generationID) AND ranked.position >= \(startOrdinal)
        AND item.eligible = TRUE AND item.expires_at > \(now)
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels label
          WHERE label.canonical_key = item.canonical_key AND label.expires_at > \(now)
            AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY ranked.position
      LIMIT \(limit)
      """,
      logger: logger
    )
    var result: [RankedRow] = []
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let position = try cells[0].decode(Int.self)
      let actorKey = try cells[13].decode(String?.self)
      let reasons = try cells[14].decode(String.self)
      result.append(
        RankedRow(
          position: position,
          item: try Self.decodeItem(
            row: row,
            offset: 1,
            reasonsJSON: reasons,
            metadataOffset: 15
          ),
          sourceActorKey: actorKey
        )
      )
    }
    return result
  }

  private func hasFallbackCorpus(now: Date) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT COUNT(*)::bigint
      FROM wire_items item
      JOIN wire_signal_rollups rollup ON rollup.canonical_key = item.canonical_key
      LEFT JOIN wire_link_metadata_cache metadata ON metadata.canonical_key = item.canonical_key
      WHERE item.eligible = TRUE AND item.expires_at > \(now)
        AND item.source_confidence >= 0.25
        AND (rollup.shares_24h >= 3 OR rollup.recommendations_24h >= 1)
        AND (
          item.provenance ? 'standard_site' OR item.source_confidence >= 0.75
          OR (metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND metadata.stale_until > \(now)
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
              metadata.icon_url) >= 2)
        )
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels label
          WHERE label.canonical_key = item.canonical_key AND label.expires_at > \(now)
            AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode(Int64.self) >= Int64(WireDataPolicy.minimumGlobalCandidates)
    }
    return false
  }

  private func simplifiedFallback(
    limit: Int,
    language: String,
    viewerDID: String?,
    now: Date
  ) async throws -> WirePage {
    let rows = try await pool.query(
      """
      SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
             item.summary, item.published_at, item.thumbnail_url, item.source_name,
             item.source_domain, item.publication_id, item.author_name,
             item.provenance::text, item.author_key, item.topic_keys::text,
             COALESCE(NULLIF(item.publication_id, ''), item.source_domain),
             item.publication_homepage_url, item.publication_icon_url
      FROM wire_items item
      JOIN wire_signal_rollups rollup ON rollup.canonical_key = item.canonical_key
      LEFT JOIN wire_link_metadata_cache metadata ON metadata.canonical_key = item.canonical_key
      WHERE item.eligible = TRUE AND item.expires_at > \(now)
        AND (\(language) = 'und' OR item.language_code = \(language))
        AND item.source_confidence >= 0.25
        AND (rollup.shares_24h >= 3 OR rollup.recommendations_24h >= 1)
        AND (
          item.provenance ? 'standard_site' OR item.source_confidence >= 0.75
          OR (metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND metadata.stale_until > \(now)
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
              metadata.icon_url) >= 2)
        )
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels label
          WHERE label.canonical_key = item.canonical_key AND label.expires_at > \(now)
            AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY (item.provenance ? 'standard_site') DESC,
               rollup.shares_24h DESC, rollup.recommendations_24h DESC,
               COALESCE(item.published_at, item.first_seen_at) DESC, item.canonical_key
      LIMIT 5000
      """,
      logger: logger
    )
    var itemsByKey: [String: WireFeedItem] = [:]
    var candidates: [WireScoredCandidate] = []
    var ordinal = 0
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let item = try Self.decodeItem(row: row, reasonsJSON: "[]", metadataOffset: 14)
      let publication = try cells[9].decode(String?.self)
      let author = try cells[12].decode(String?.self)
      let topicsJSON = try cells[13].decode(String.self)
      let topics = (try? JSONDecoder().decode([String].self, from: Data(topicsJSON.utf8))) ?? []
      itemsByKey[item.itemID] = item
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
            firstSeenAt: now
          ),
          score: Double(5_000 - ordinal),
          reasonCodes: []
        )
      )
      ordinal += 1
    }
    if Self.requiresGlobalFallback(
      requestedLanguage: language,
      localizedCandidateCount: candidates.count
    ) {
      return try await simplifiedFallback(
        limit: limit,
        language: "und",
        viewerDID: viewerDID,
        now: now
      )
    }
    let reranked = WireDiversityReranker.rerank(candidates, policy: WireDiversityPolicy())
    let moderation = try await moderationSnapshot(viewerDID: viewerDID, now: now)
    let items = reranked.items.compactMap { candidate -> WireFeedItem? in
      guard let item = itemsByKey[candidate.candidate.canonicalKey] else { return nil }
      guard moderation?.allows(
        item: candidate.candidate.authorKey ?? item.itemID,
        title: item.title,
        summary: item.summary,
        representativeURI: item.representativeURI
      ) ?? true else { return nil }
      return item
    }.prefix(limit)
    let bucket = Int(now.timeIntervalSince1970 / 300)
    return WirePage(
      generationID: "fallback-\(bucket)",
      generatedAt: Date(timeIntervalSince1970: Double(bucket * 300)),
      language: language,
      cursor: nil,
      source: .simplifiedFallback,
      degraded: true,
      items: Array(items)
    )
  }

  static func requiresGlobalFallback(
    requestedLanguage: String,
    localizedCandidateCount: Int
  ) -> Bool {
    requestedLanguage != "und"
      && localizedCandidateCount < WireDataPolicy.diverseFirstPageCount
  }

  private static func decodeItem(
    row: PostgresRow,
    offset: Int = 0,
    reasonsJSON: String,
    metadataOffset: Int? = nil
  ) throws -> WireFeedItem {
    let cells = row.makeRandomAccess()
    let itemID = try cells[offset].decode(String.self)
    let canonicalURL = try cells[offset + 1].decode(String.self)
    let representativeURI = try cells[offset + 2].decode(String?.self)
    let title = try cells[offset + 3].decode(String.self)
    let summary = try cells[offset + 4].decode(String?.self)
    let publishedAt = try cells[offset + 5].decode(Date?.self)
    let thumbnailURL = try cells[offset + 6].decode(String?.self)
    let sourceName = try cells[offset + 7].decode(String.self)
    let sourceDomain = try cells[offset + 8].decode(String.self)
    let publication = try cells[offset + 9].decode(String?.self)
    let authorName = try cells[offset + 10].decode(String?.self)
    let provenanceJSON = try cells[offset + 11].decode(String.self)
    let decoder = JSONDecoder()
    let reasons = (try? decoder.decode([WireReasonCode].self, from: Data(reasonsJSON.utf8))) ?? []
    let provenance =
      (try? decoder.decode([WireProvenanceKind].self, from: Data(provenanceJSON.utf8))) ?? []
    return WireFeedItem(
      itemID: itemID,
      canonicalURL: canonicalURL,
      representativeURI: representativeURI,
      title: title,
      summary: summary,
      publishedAt: publishedAt,
      thumbnailURL: thumbnailURL,
      source: WireItemSource(
        name: sourceName,
        domain: sourceDomain,
        publication: publication,
        author: authorName,
        publicationKey: try metadataOffset.map { try cells[$0].decode(String?.self) } ?? nil,
        homepageURL: try metadataOffset.map { try cells[$0 + 1].decode(String?.self) } ?? nil,
        iconURL: try metadataOffset.map { try cells[$0 + 2].decode(String?.self) } ?? nil
      ),
      reasons: reasons,
      provenance: provenance
    )
  }

  private func materializedTalkedAccounts(
    generationID: UUID,
    viewerDID: String?,
    now: Date
  ) async throws -> [WireTalkedAboutAccount] {
    let rows = try await pool.query(
      """
      SELECT selected.position, profile.subject_did, profile.handle,
             profile.display_name, profile.avatar_url, profile.description
      FROM wire_edition_talked_accounts selected
      JOIN wire_talked_accounts profile ON profile.subject_did = selected.subject_did
      WHERE selected.generation_id = \(generationID)
        AND profile.status = 'fresh' AND profile.expires_at > \(now)
      ORDER BY selected.position
      LIMIT 10
      """,
      logger: logger
    )
    let moderation = try await moderationSnapshot(viewerDID: viewerDID, now: now)
    var result: [WireTalkedAboutAccount] = []
    for try await row in rows {
      let value = try row.decode((Int, String, String?, String?, String?, String?).self)
      guard moderation?.allows(
        item: value.1,
        title: value.3 ?? value.2 ?? value.1,
        summary: nil,
        representativeURI: nil
      ) ?? true else { continue }
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

  private func latestMaterializedTalkedAccounts(
    language: String,
    viewerDID: String?,
    now: Date
  ) async throws -> [WireTalkedAboutAccount] {
    let rows = try await pool.query(
      """
      SELECT generation.generation_id
      FROM wire_edition_generations edition
      JOIN wire_rank_generations generation ON generation.generation_id = edition.generation_id
      WHERE edition.language_bucket = \(language)
        AND generation.feed_key = 'wire'
        AND generation.status IN ('committed', 'superseded')
        AND EXISTS (
          SELECT 1 FROM wire_edition_talked_accounts account
          WHERE account.generation_id = generation.generation_id
        )
      ORDER BY generation.generated_at DESC, generation.generation_id DESC
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try await materializedTalkedAccounts(
        generationID: row.decode(UUID.self),
        viewerDID: viewerDID,
        now: now
      )
    }
    return []
  }

  private static func primaryLanguage(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let primary = normalized.split(separator: "-").first,
      primary.count >= 2, primary.count <= 8,
      primary.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return "und" }
    return String(primary)
  }

  private func moderationSnapshot(
    viewerDID: String?,
    now: Date
  ) async throws -> WireViewerModerationSnapshot? {
    guard let viewerDID else { return nil }
    guard let snapshot = await moderationCache.usable(viewerDID: viewerDID, now: now) else {
      throw WireServingError.moderationUnavailable
    }
    return snapshot
  }
}
