import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresCircleCandidateFetcher: CircleCandidateFetching {
  private let pool: PostgresClient
  private let logger: Logger

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  func candidates(
    actorHashes: [String],
    language: String,
    since: Date,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusCandidateResponse {
    let generationRows = try await pool.query(
      """
      SELECT generation_id::text
      FROM wire_serving.feed_state
      WHERE language_bucket = \(language)
      LIMIT 1
      """,
      logger: logger
    )
    var generationID = "circle-\(Int(now.timeIntervalSince1970 / 300))"
    for try await row in generationRows { generationID = try row.decode(String.self) }
    let rows = try await pool.query(
      """
      WITH matched AS MATERIALIZED (
        SELECT * FROM wire_serving.circle_signal_facts
        WHERE actor_key_hash = ANY(\(actorHashes))
          AND occurred_at >= \(since)
          AND (\(language) = 'und' OR language_code = \(language))
      ), selected AS (
        SELECT canonical_key, COUNT(DISTINCT actor_key_hash) AS participant_count,
               MAX(occurred_at) AS latest_signal
        FROM matched GROUP BY canonical_key
        ORDER BY participant_count DESC, latest_signal DESC, canonical_key
        LIMIT \(limit)
      )
      SELECT matched.canonical_key, canonical_url, representative_uri, title, summary,
             published_at, thumbnail_url, source_name, source_domain, publication_id,
             author_name, provenance::text, publication_key, publication_homepage_url,
             publication_icon_url, topic_keys::text, actor_key_hash, signal_kind, source_collection,
             source_action, source_uri, occurred_at
      FROM matched JOIN selected USING (canonical_key)
      ORDER BY selected.participant_count DESC, selected.latest_signal DESC,
               matched.canonical_key, matched.occurred_at DESC, matched.actor_key_hash
      """,
      logger: logger
    )
    let decoder = JSONDecoder()
    var order: [String] = []
    var items: [String: WireFeedItem] = [:]
    var topics: [String: [String]] = [:]
    var facts: [String: [WireCorpusSignalFact]] = [:]
    for try await row in rows {
      let cells = row.makeRandomAccess()
      let key = try cells[0].decode(String.self)
      if items[key] == nil {
        order.append(key)
        let provenanceJSON = try cells[11].decode(String.self)
        items[key] = WireFeedItem(
          itemID: key,
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
            publicationKey: try cells[12].decode(String?.self),
            homepageURL: try cells[13].decode(String?.self),
            iconURL: try cells[14].decode(String?.self)
          ),
          reasons: [],
          provenance: (try? decoder.decode(
            [WireProvenanceKind].self,
            from: Data(provenanceJSON.utf8)
          )) ?? []
        )
        let topicsJSON = try cells[15].decode(String.self)
        topics[key] = (try? decoder.decode([String].self, from: Data(topicsJSON.utf8))) ?? []
      }
      guard let kind = WireSignalKind(rawValue: try cells[17].decode(String.self)) else {
        throw WireServingError.corpusContractMismatch
      }
      facts[key, default: []].append(
        WireCorpusSignalFact(
          actorHash: try cells[16].decode(String.self),
          kind: kind,
          sourceCollection: try cells[18].decode(String.self),
          sourceAction: try cells[19].decode(String.self),
          sourceURI: try cells[20].decode(String.self),
          occurredAt: try cells[21].decode(Date.self)
        )
      )
    }
    let stories = order.compactMap { key -> WireCorpusCandidateStory? in
      guard let item = items[key] else { return nil }
      return WireCorpusCandidateStory(
        item: item, topicKeys: topics[key] ?? [], facts: facts[key] ?? [])
    }
    return WireCorpusCandidateResponse(
      generationID: generationID,
      generatedAt: now,
      language: language,
      stories: stories,
      exhausted: stories.count < limit
    )
  }
}
