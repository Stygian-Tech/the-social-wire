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
  }

  private let pool: PostgresClient
  private let logger: Logger

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  func ping() async throws {
    let rows = try await pool.query(
      "SELECT contract_version FROM wire_serving.contract LIMIT 1",
      logger: logger
    )
    for try await row in rows {
      guard try row.decode(Int.self) == 1 else {
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
      guard let retained = try await retainedGeneration(id: generationID, now: now) else {
        throw WireCorpusEdgeStoreError.cursorExpired
      }
      generation = retained
    } else if let active = try await activeGeneration(language: language) {
      if now.timeIntervalSince(active.generatedAt) > 30 * 60 {
        return try await fallback(language: language, limit: limit, now: now)
      }
      generation = active
    } else {
      return try await fallback(language: language, limit: limit, now: now)
    }

    let rows = try await rankedRows(
      generationID: generation.id,
      startOrdinal: startOrdinal,
      limit: limit
    )
    let age = now.timeIntervalSince(generation.generatedAt)
    return WireCorpusPage(
      generationID: generation.id.uuidString.lowercased(),
      generatedAt: generation.generatedAt,
      language: generation.language,
      source: age > 10 * 60 ? .staleGeneration : .ranked,
      degraded: age > 10 * 60,
      rows: rows,
      exhausted: rows.count < limit
    )
  }

  func item(id: String, now: Date) async throws -> WireCorpusItem? {
    try await requireFreshBaseline(now: now)
    let rows = try await pool.query(
      """
      SELECT canonical_key, canonical_url, representative_uri, title, summary, published_at,
             thumbnail_url, source_name, source_domain, publication_id, author_name,
             provenance::text, author_key
      FROM wire_serving.items
      WHERE canonical_key = \(id)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return WireCorpusItem(
        item: try Self.decodeItem(row: row, reasonsJSON: "[]"),
        sourceActorKey: try row.makeRandomAccess()[12].decode(String?.self)
      )
    }
    return nil
  }

  func catalog(now: Date) async throws -> WireCorpusCatalog {
    try await requireFreshBaseline(now: now)
    let generations = try await acceptableGenerations(now: now)
    let latest = generations.max { $0.generatedAt < $1.generatedAt }
    let fallbackAvailable = latest == nil ? try await hasFallbackCorpus() : false
    return WireCorpusCatalog(
      available: latest != nil || fallbackAvailable,
      supportedLanguages: generations.map(\.language).filter { $0 != "und" }.sorted(),
      latestGenerationID: latest?.id.uuidString.lowercased(),
      generatedAt: latest?.generatedAt
    )
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
      SELECT generation_id, language_bucket, generated_at, expires_at
      FROM wire_serving.feed_state
      WHERE language_bucket = \(language)
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
      FROM wire_serving.generations
      WHERE generation_id = \(id) AND expires_at > \(now)
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
      SELECT generation_id, language_bucket, generated_at, expires_at
      FROM wire_serving.feed_state
      WHERE generated_at >= \(now.addingTimeInterval(-30 * 60))
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

  private func rankedRows(
    generationID: UUID,
    startOrdinal: Int,
    limit: Int
  ) async throws -> [WireCorpusRow] {
    let rows = try await pool.query(
      """
      SELECT position, canonical_key, canonical_url, representative_uri, title, summary,
             published_at, thumbnail_url, source_name, source_domain, publication_id,
             author_name, provenance::text, author_key, reason_codes::text
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
            reasonsJSON: try cells[14].decode(String.self)
          ),
          sourceActorKey: try cells[13].decode(String?.self)
        )
      )
    }
    return result
  }

  private func hasFallbackCorpus() async throws -> Bool {
    let rows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM wire_serving.fallback_items",
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
             provenance::text, author_key, topic_keys::text, first_seen_at
      FROM wire_serving.fallback_items
      WHERE (\(language) = 'und' OR language_code = \(language))
      ORDER BY COALESCE(published_at, first_seen_at) DESC, canonical_key
      LIMIT 5000
      """,
      logger: logger
    )
    var itemsByKey: [String: (WireFeedItem, String?)] = [:]
    var candidates: [WireScoredCandidate] = []
    var ordinal = 0
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let item = try Self.decodeItem(row: row, reasonsJSON: "[]")
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
    if language != "und", candidates.count < WireDataPolicy.diverseFirstPageCount {
      return try await fallback(language: "und", limit: limit, now: now)
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
    reasonsJSON: String
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
        author: try cells[offset + 10].decode(String?.self)
      ),
      reasons: (try? decoder.decode([WireReasonCode].self, from: Data(reasonsJSON.utf8))) ?? [],
      provenance: (try? decoder.decode([WireProvenanceKind].self, from: Data(provenanceJSON.utf8))) ?? []
    )
  }
}
