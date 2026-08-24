import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireGenerationStore: WireGenerationStore {
  let pool: PostgresClient
  let logger: Logger

  func ping() async throws {
    let rows = try await pool.query("SELECT 1", logger: logger)
    for try await _ in rows { return }
  }

  func eligibleLanguageBuckets(
    limit: Int,
    minimumCandidates: Int,
    asOf: Date
  ) async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT i.language_code
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > \(asOf)
        AND i.target_kind IN ('external_article', 'standard_site_document')
        AND i.commercial_class <> 'probable_ad'
        AND i.language_code <> 'und'
        AND i.source_confidence >= 0.25
        AND (r.shares_24h >= 3 OR r.recommendations_24h >= 1)
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > \(asOf)
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      GROUP BY i.language_code
      HAVING COUNT(*) >= \(minimumCandidates)
      ORDER BY COUNT(*) DESC, i.language_code
      LIMIT \(max(0, min(limit, 12)))
      """,
      logger: logger
    )
    var result: [String] = []
    for try await row in rows { result.append(try row.decode(String.self)) }
    return result
  }

  func loadCandidates(
    languageBucket: String,
    limit: Int,
    asOf: Date
  ) async throws -> [WireCandidate] {
    let rows = try await pool.query(
      """
      SELECT i.canonical_key, i.canonical_url, i.representative_uri, i.source_domain,
             i.publication_id, i.author_key, i.topic_keys::text, i.published_at,
             i.first_seen_at, i.last_signal_at, i.source_confidence,
             (i.provenance ? 'standard_site') AS is_standard_site,
             COALESCE(metadata.source = 'open_graph'
               AND metadata.status IN ('fresh', 'stale')
               AND metadata.stale_until > \(asOf)
               AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
                 metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
                 metadata.icon_url) >= 2, FALSE) AS has_usable_open_graph,
             i.target_kind, i.commercial_class, i.commercial_score,
             r.distinct_actors_1h, r.distinct_actors_24h, r.distinct_actors_7d,
             r.signals_1h, r.signals_24h, r.signals_7d, r.communities_24h,
             r.primary_community_key_hash, r.recommendations_24h,
             r.positive_feedback_24h, r.negative_feedback_24h,
             r.shares_1h, r.shares_24h, r.distinct_likers_24h, r.likes_1h, r.likes_24h,
             r.distinct_reposters_24h, r.reposts_1h, r.reposts_24h
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      LEFT JOIN wire_link_metadata_cache metadata ON metadata.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > \(asOf)
        AND i.target_kind IN ('external_article', 'standard_site_document')
        AND i.commercial_class <> 'probable_ad'
        AND (\(languageBucket) = 'und' OR i.language_code = \(languageBucket))
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > \(asOf)
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY
        CASE
          WHEN r.shares_24h >= 5 OR r.recommendations_24h >= 2 THEN 0
          WHEN (i.provenance ? 'standard_site') AND r.shares_24h >= 3 THEN 1
          WHEN (r.shares_24h >= 3 OR r.recommendations_24h >= 1) THEN 2
          ELSE 3
        END,
        r.shares_24h DESC, r.recommendations_24h DESC,
        (i.provenance ? 'standard_site') DESC,
        has_usable_open_graph DESC, r.signals_1h DESC, i.canonical_key
      LIMIT \(limit)
      """,
      logger: logger
    )
    var candidates: [WireCandidate] = []
    for try await row in rows {
      let identity = try row.decode(
        (String, String, String?, String, String?, String?, String, Date?, Date, Date?, Double).self
      )
      let cells = row.makeRandomAccess()
      let isStandardSite = try cells[11].decode(Bool.self)
      let hasUsableOpenGraph = try cells[12].decode(Bool.self)
      let targetKind = WireTargetKind(rawValue: try cells[13].decode(String.self)) ?? .unsupported
      let commercialClass = WireCommercialClass(
        rawValue: try cells[14].decode(String.self)) ?? .probableAd
      let commercialScore = try cells[15].decode(Double.self)
      let rollup = try (
        cells[16].decode(Int.self), cells[17].decode(Int.self),
        cells[18].decode(Int.self), cells[19].decode(Int.self),
        cells[20].decode(Int.self), cells[21].decode(Int.self),
        cells[22].decode(Int.self), cells[23].decode(String?.self),
        cells[24].decode(Int.self), cells[25].decode(Int.self),
        cells[26].decode(Int.self), cells[27].decode(Int.self),
        cells[28].decode(Int.self), cells[29].decode(Int.self),
        cells[30].decode(Int.self), cells[31].decode(Int.self),
        cells[32].decode(Int.self), cells[33].decode(Int.self),
        cells[34].decode(Int.self)
      )
      let topics = (try? JSONDecoder().decode([String].self, from: Data(identity.6.utf8))) ?? []
      candidates.append(
        WireCandidate(
          canonicalKey: identity.0,
          canonicalURL: identity.1,
          representativeURI: identity.2,
          sourceDomain: identity.3,
          publicationID: identity.4,
          authorKey: identity.5,
          topicKeys: topics,
          publishedAt: identity.7,
          firstSeenAt: identity.8,
          lastSignalAt: identity.9,
          distinctActors1h: rollup.0,
          distinctActors24h: rollup.1,
          distinctActors7d: rollup.2,
          signals1h: rollup.3,
          signals24h: rollup.4,
          signals7d: rollup.5,
          communities24h: rollup.6,
          primaryCommunityKey: rollup.7,
          recommendations24h: rollup.8,
          positiveFeedback24h: rollup.9,
          negativeFeedback24h: rollup.10,
          shares1h: rollup.11,
          shares24h: rollup.12,
          distinctLikes24h: rollup.13,
          likes1h: rollup.14,
          likes24h: rollup.15,
          distinctReposts24h: rollup.16,
          reposts1h: rollup.17,
          reposts24h: rollup.18,
          sourceConfidence: identity.10,
          isStandardSite: isStandardSite,
          hasUsableOpenGraphMetadata: hasUsableOpenGraph,
          targetKind: targetKind,
          commercialClass: commercialClass,
          commercialScore: commercialScore
        )
      )
    }
    return candidates
  }

  func commit(_ generation: WireGenerationCommit) async throws {
    let diagnostics = try json(generation.result.diagnostics)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
        VALUES (\(generation.feedKey), \(generation.languageBucket), NULL, \(generation.generatedAt))
        ON CONFLICT (feed_key, language_bucket) DO NOTHING
        """,
        logger: logger
      )
      _ = try await connection.query(
        """
        SELECT active_generation_id FROM wire_feed_state
        WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
        FOR UPDATE
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, committed_at, expires_at, candidate_count, ranked_count, diagnostics)
        VALUES
          (\(generation.generationID), \(generation.feedKey), \(generation.languageBucket),
           'building', FALSE, \(generation.configVersion), \(generation.generatedAt), NULL,
           \(generation.expiresAt), \(generation.result.diagnostics.candidateCount),
           \(generation.result.items.count), \(diagnostics)::jsonb)
        """,
        logger: logger
      )
      for (position, item) in generation.result.items.enumerated() {
        let reasons = try json(item.reasonCodes.map(\.rawValue))
        try await connection.query(
          """
          INSERT INTO wire_ranked_items
            (generation_id, position, canonical_key, score, reason_codes, diversity_metadata)
          VALUES
            (\(generation.generationID), \(position), \(item.candidate.canonicalKey), \(item.score),
             \(reasons)::jsonb, '{}'::jsonb)
          """,
          logger: logger
        )
      }

      let editionRows = try await connection.query(
        """
        SELECT ranked.position, item.canonical_key, item.canonical_url, item.representative_uri,
               item.title, item.summary, item.published_at, item.thumbnail_url, item.source_name,
               item.source_domain, item.publication_id, item.author_name, item.provenance::text,
               ranked.reason_codes::text,
               COALESCE(NULLIF(item.publication_id, ''), item.source_domain),
               item.publication_homepage_url, item.publication_icon_url
        FROM wire_ranked_items ranked
        JOIN wire_items item ON item.canonical_key = ranked.canonical_key
        WHERE ranked.generation_id = \(generation.generationID) AND ranked.position < 50
        ORDER BY ranked.position
        """,
        logger: logger
      )
      let decoder = JSONDecoder()
      var editionItems: [WireFeedItem] = []
      for try await row in editionRows {
        let cells = row.makeRandomAccess()
        let provenanceJSON = try cells[12].decode(String.self)
        let reasonsJSON = try cells[13].decode(String.self)
        editionItems.append(
          WireFeedItem(
            itemID: try cells[1].decode(String.self),
            canonicalURL: try cells[2].decode(String.self),
            representativeURI: try cells[3].decode(String?.self),
            title: try cells[4].decode(String.self),
            summary: try cells[5].decode(String?.self),
            publishedAt: try cells[6].decode(Date?.self),
            thumbnailURL: try cells[7].decode(String?.self),
            source: WireItemSource(
              name: try cells[8].decode(String.self),
              domain: try cells[9].decode(String.self),
              publication: try cells[10].decode(String?.self),
              author: try cells[11].decode(String?.self),
              publicationKey: try cells[14].decode(String?.self),
              homepageURL: try cells[15].decode(String?.self),
              iconURL: try cells[16].decode(String?.self)
            ),
            reasons: (try? decoder.decode(
              [WireReasonCode].self, from: Data(reasonsJSON.utf8)
            )) ?? [],
            provenance: (try? decoder.decode(
              [WireProvenanceKind].self, from: Data(provenanceJSON.utf8)
            )) ?? []
          )
        )
      }

      let accountRows = try await connection.query(
        """
        SELECT mentions.subject_did, profile.handle, profile.display_name, profile.avatar_url,
               profile.description,
               COUNT(DISTINCT mentions.canonical_key)::bigint,
               COUNT(DISTINCT mentions.speaker_key_hash)::bigint,
               MIN(ranked.position), MAX(mentions.occurred_at)
        FROM wire_item_mentions mentions
        JOIN wire_talked_accounts profile ON profile.subject_did = mentions.subject_did
        JOIN wire_ranked_items ranked
          ON ranked.generation_id = \(generation.generationID)
         AND ranked.canonical_key = mentions.canonical_key
        WHERE mentions.expires_at > \(generation.generatedAt)
          AND profile.status = 'fresh'
          AND profile.expires_at > \(generation.generatedAt)
          AND ranked.position < 50
        GROUP BY mentions.subject_did, profile.handle, profile.display_name,
                 profile.avatar_url, profile.description
        HAVING COUNT(DISTINCT mentions.canonical_key) >= 2
           AND COUNT(DISTINCT mentions.speaker_key_hash) >= 3
        ORDER BY COUNT(DISTINCT mentions.canonical_key) DESC,
                 COUNT(DISTINCT mentions.speaker_key_hash) DESC,
                 MIN(ranked.position), MAX(mentions.occurred_at) DESC,
                 mentions.subject_did
        LIMIT 10
        """,
        logger: logger
      )
      var accountCandidates: [WireTalkedAboutAccountCandidate] = []
      for try await row in accountRows {
        let value = try row.decode(
          (String, String?, String?, String?, String?, Int64, Int64, Int, Date).self
        )
        accountCandidates.append(
          WireTalkedAboutAccountCandidate(
            account: WireTalkedAboutAccount(
              did: value.0,
              handle: value.1,
              displayName: value.2,
              avatarURL: value.3,
              description: value.4
            ),
            distinctStoryCount: Int(value.5),
            distinctSpeakerCount: Int(value.6),
            bestStoryRank: value.7,
            latestMentionAt: value.8
          )
        )
      }
      let edition = WireEditionAssembler.assemble(
        generationID: generation.generationID.uuidString.lowercased(),
        generatedAt: generation.generatedAt,
        language: generation.languageBucket,
        source: .ranked,
        degraded: false,
        rankedItems: editionItems,
        talkedAboutAccountCandidates: accountCandidates
      )
      let topicsByItemID = Dictionary(uniqueKeysWithValues: generation.result.items.map {
        ($0.candidate.canonicalKey, $0.candidate.topicKeys)
      })
      let reasonsByItemID = Dictionary(uniqueKeysWithValues: generation.result.items.map {
        ($0.candidate.canonicalKey, $0.reasonCodes)
      })
      let outsideUSItems = WireRegionalEditionRanker.downrankAmericanPolitics(
        in: editionItems,
        topicKeys: { topicsByItemID[$0.itemID] ?? [] },
        reasons: { reasonsByItemID[$0.itemID] ?? [] }
      )
      let outsideUSEdition = WireEditionAssembler.assemble(
        generationID: generation.generationID.uuidString.lowercased(),
        generatedAt: generation.generatedAt,
        language: generation.languageBucket,
        source: .ranked,
        degraded: false,
        rankedItems: outsideUSItems,
        talkedAboutAccountCandidates: accountCandidates
      )
      let continuationOrdinal = min(50, generation.result.items.count)
      try await connection.query(
        """
        INSERT INTO wire_edition_generations
          (generation_id, algorithm_version, language_bucket, continuation_ordinal, materialized_at)
        VALUES
          (\(generation.generationID), \(edition.algorithmVersion), \(generation.languageBucket),
           \(continuationOrdinal), \(generation.generatedAt))
        """,
        logger: logger
      )

      func insertEdition(_ value: WireEdition, namespace: String?) async throws {
        // Positions are unique across every variant in a generation.
        var modulePosition = namespace == nil ? 0 : 1_000
        let prefix = namespace.map { "\($0):" } ?? ""
        func insertModule(
          key: String,
          kind: String,
          title: String?,
          reason: String?,
          publication: WireEditionPublication?,
          stories: [WireFeedItem]
        ) async throws {
          guard !stories.isEmpty else { return }
          let storedKey = "\(prefix)\(key)"
          try await connection.query(
            """
            INSERT INTO wire_edition_modules
              (generation_id, module_key, module_kind, title, position, reason_code,
               publication_key, publication_name, publication_domain,
               publication_homepage_url, publication_icon_url)
            VALUES
              (\(generation.generationID), \(storedKey), \(kind), \(title), \(modulePosition), \(reason),
               \(publication?.key), \(publication?.name), \(publication?.domain),
               \(publication?.homepageURL), \(publication?.iconURL))
            """,
            logger: logger
          )
          for (position, story) in stories.enumerated() {
            try await connection.query(
              """
              INSERT INTO wire_edition_module_items
                (generation_id, module_key, position, canonical_key)
              VALUES (\(generation.generationID), \(storedKey), \(position), \(story.itemID))
              """,
              logger: logger
            )
          }
          modulePosition += 1
        }
        try await insertModule(
          key: "top-stories", kind: "top_stories", title: "Top Stories", reason: nil,
          publication: nil, stories: value.leadStories
        )
        for (index, panel) in value.publicationPanels.enumerated() {
          try await insertModule(
            key: "publication-\(index)", kind: "publication_spotlight",
            title: panel.publication.name, reason: nil,
            publication: panel.publication, stories: panel.stories
          )
        }
        for rail in value.storyRails {
          try await insertModule(
            key: rail.id, kind: "story_rail", title: rail.title,
            reason: rail.reason.rawValue, publication: nil, stories: rail.stories
          )
        }
        try await insertModule(
          key: "general", kind: "general", title: "More Across the Social Web", reason: nil,
          publication: nil, stories: value.generalStories
        )
        try await insertModule(
          key: "trending", kind: "trending", title: "Trending", reason: nil,
          publication: nil, stories: value.trendingStories
        )
      }
      try await insertEdition(edition, namespace: nil)
      try await insertEdition(outsideUSEdition, namespace: WireViewerRegion.outsideUnitedStates.rawValue)
      for (position, account) in edition.talkedAboutAccounts.enumerated() {
        try await connection.query(
          """
          INSERT INTO wire_edition_talked_accounts (generation_id, position, subject_did)
          VALUES (\(generation.generationID), \(position), \(account.did))
          """,
          logger: logger
        )
      }

      if generation.activate {
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'superseded', is_active = FALSE
          WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
            AND is_active = TRUE
          """,
          logger: logger
        )
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'committed', is_active = TRUE, committed_at = \(generation.generatedAt)
          WHERE generation_id = \(generation.generationID)
          """,
          logger: logger
        )
        try await connection.query(
          """
          UPDATE wire_feed_state
          SET active_generation_id = \(generation.generationID), updated_at = \(generation.generatedAt)
          WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
          """,
          logger: logger
        )
      } else {
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'shadow', committed_at = \(generation.generatedAt)
          WHERE generation_id = \(generation.generationID)
          """,
          logger: logger
        )
      }
    }
  }

  func deleteExpired(asOf: Date, batchSize: Int) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        DELETE FROM wire_rank_generations
        WHERE generation_id IN (
          SELECT generation_id FROM wire_rank_generations
          WHERE expires_at <= \(asOf) AND is_active = FALSE
          ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_signal_events
        WHERE (occurred_at, id) IN (
          SELECT occurred_at, id FROM wire_signal_events WHERE expires_at <= \(asOf)
          ORDER BY expires_at, occurred_at, id LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_follow_edges
        WHERE (follower_key_hash, followee_key_hash) IN (
          SELECT follower_key_hash, followee_key_hash FROM wire_follow_edges
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_actor_communities
        WHERE actor_key_hash IN (
          SELECT actor_key_hash FROM wire_actor_communities
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_active_actors
        WHERE actor_key_hash IN (
          SELECT actor_key_hash FROM wire_active_actors
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_publications
        WHERE publication_uri IN (
          SELECT publication_uri FROM wire_publications
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_item_aliases
        WHERE alias_key IN (
          SELECT alias_key FROM wire_item_aliases
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_labels
        WHERE (canonical_key, label_key, source) IN (
          SELECT canonical_key, label_key, source FROM wire_labels
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_items
        WHERE canonical_key IN (
          SELECT canonical_key FROM wire_items WHERE expires_at <= \(asOf)
          ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
    }
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
}
