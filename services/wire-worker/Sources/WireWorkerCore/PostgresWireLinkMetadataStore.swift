import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireLinkMetadataStore: WireLinkMetadataStoring {
  let pool: PostgresClient
  let logger: Logger

  func seedEmbedded(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO wire_link_metadata_cache
        (canonical_key, canonical_url, title, description, image_url, site_name, author_name,
         published_at, icon_url,
         etag, last_modified, source, status, fetched_at, fresh_until, stale_until,
         retry_after, failure_count, updated_at)
      VALUES
        (\(canonicalKey), \(metadata.canonicalURL), \(metadata.title), \(metadata.description),
         \(metadata.imageURL), \(metadata.siteName), \(metadata.authorName),
         \(metadata.publishedAt), \(metadata.iconURL), NULL, NULL,
         'embedded_card', 'pending', \(asOf), \(asOf), \(asOf.addingTimeInterval(7 * 86_400)),
         \(asOf), 0, \(asOf))
      ON CONFLICT (canonical_key) DO UPDATE SET
        title = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.title ELSE COALESCE(EXCLUDED.title, wire_link_metadata_cache.title) END,
        description = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.description ELSE COALESCE(EXCLUDED.description, wire_link_metadata_cache.description) END,
        image_url = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.image_url ELSE COALESCE(EXCLUDED.image_url, wire_link_metadata_cache.image_url) END,
        author_name = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.author_name ELSE COALESCE(EXCLUDED.author_name, wire_link_metadata_cache.author_name) END,
        published_at = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.published_at ELSE COALESCE(EXCLUDED.published_at, wire_link_metadata_cache.published_at) END,
        stale_until = GREATEST(wire_link_metadata_cache.stale_until, EXCLUDED.stale_until),
        retry_after = LEAST(wire_link_metadata_cache.retry_after, EXCLUDED.retry_after),
        updated_at = EXCLUDED.updated_at
      WHERE ROW(
        wire_link_metadata_cache.title,
        wire_link_metadata_cache.description,
        wire_link_metadata_cache.image_url,
        wire_link_metadata_cache.author_name,
        wire_link_metadata_cache.published_at,
        wire_link_metadata_cache.stale_until,
        wire_link_metadata_cache.retry_after)
        IS DISTINCT FROM ROW(CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.title ELSE COALESCE(EXCLUDED.title, wire_link_metadata_cache.title) END,
        CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.description ELSE COALESCE(EXCLUDED.description, wire_link_metadata_cache.description) END,
        CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.image_url ELSE COALESCE(EXCLUDED.image_url, wire_link_metadata_cache.image_url) END,
        CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.author_name ELSE COALESCE(EXCLUDED.author_name, wire_link_metadata_cache.author_name) END,
        CASE WHEN wire_link_metadata_cache.source = 'open_graph'
          THEN wire_link_metadata_cache.published_at ELSE COALESCE(EXCLUDED.published_at, wire_link_metadata_cache.published_at) END,
        GREATEST(wire_link_metadata_cache.stale_until, EXCLUDED.stale_until),
        LEAST(wire_link_metadata_cache.retry_after, EXCLUDED.retry_after))
      """,
      logger: logger
    )
  }

  func claimDue(limit: Int, asOf: Date) async throws -> [WireLinkMetadataTarget] {
    let boundedLimit = max(1, min(limit, 250))
    let priorityLimit = boundedLimit == 1 ? 1 : max(1, boundedLimit * 3 / 4)
    return try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, source, status, fetched_at, fresh_until, stale_until,
           retry_after, failure_count, updated_at)
        SELECT canonical_key, canonical_url, 'fallback', 'pending', NULL, NULL, NULL, \(asOf), 0, \(asOf)
        FROM wire_items item
        WHERE item.eligible = TRUE AND item.expires_at > \(asOf)
          AND item.canonical_url LIKE 'https://%'
          AND NOT EXISTS (
            SELECT 1 FROM wire_link_metadata_cache cache
            WHERE cache.canonical_key = item.canonical_key
          )
        ORDER BY item.last_signal_at DESC NULLS LAST, item.canonical_key
        LIMIT \(boundedLimit * 4)
        ON CONFLICT (canonical_key) DO NOTHING
        """,
        logger: logger
      )
      let priorityRows = try await connection.query(
        """
        WITH due AS (
          SELECT cache.canonical_key
          FROM wire_items item
          JOIN wire_link_metadata_cache cache ON cache.canonical_key = item.canonical_key
          WHERE item.language_code = 'und'
            AND item.eligible = TRUE AND item.expires_at > \(asOf)
            AND item.target_kind IN ('external_article', 'standard_site_document')
            AND item.commercial_class <> 'probable_ad'
            AND item.source_confidence >= 0.25
            AND cache.language_checked_at IS NULL
            AND cache.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (cache.retry_after <= \(asOf)
                AND (cache.fresh_until IS NULL OR cache.fresh_until <= \(asOf)))
              OR (cache.source = 'open_graph' AND cache.status IN ('fresh', 'stale')
                AND cache.language_checked_at IS NULL)
            )
          ORDER BY item.last_signal_at DESC NULLS LAST, cache.retry_after, cache.canonical_key
          FOR UPDATE OF cache SKIP LOCKED
          LIMIT \(priorityLimit)
        )
        UPDATE wire_link_metadata_cache cache
        SET status = 'fetching', retry_after = \(asOf.addingTimeInterval(300)),
            fresh_until = CASE WHEN cache.language_checked_at IS NULL
              THEN LEAST(COALESCE(cache.fresh_until, \(asOf)), \(asOf))
              ELSE cache.fresh_until END,
            updated_at = \(asOf)
        FROM due
        WHERE cache.canonical_key = due.canonical_key
        RETURNING cache.canonical_key, cache.canonical_url,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.etag END,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END
        """,
        logger: logger
      )
      var targets: [WireLinkMetadataTarget] = []
      for try await row in priorityRows {
        let value = try row.decode((String, String, String?, String?).self)
        targets.append(
          WireLinkMetadataTarget(
            canonicalKey: value.0,
            canonicalURL: value.1,
            etag: value.2,
            lastModified: value.3
          )
        )
      }
      let remaining = boundedLimit - targets.count
      guard remaining > 0 else { return targets }
      let generalRows = try await connection.query(
        """
        WITH due AS (
          SELECT canonical_key
          FROM wire_link_metadata_cache
          WHERE status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (retry_after <= \(asOf) AND (fresh_until IS NULL OR fresh_until <= \(asOf)))
              OR (source = 'open_graph' AND status IN ('fresh', 'stale')
                AND language_checked_at IS NULL)
            )
          ORDER BY language_checked_at NULLS FIRST, retry_after, canonical_key
          FOR UPDATE SKIP LOCKED
          LIMIT \(remaining)
        )
        UPDATE wire_link_metadata_cache cache
        SET status = 'fetching', retry_after = \(asOf.addingTimeInterval(300)),
            fresh_until = CASE WHEN cache.language_checked_at IS NULL
              THEN LEAST(COALESCE(cache.fresh_until, \(asOf)), \(asOf))
              ELSE cache.fresh_until END,
            updated_at = \(asOf)
        FROM due
        WHERE cache.canonical_key = due.canonical_key
        RETURNING cache.canonical_key, cache.canonical_url,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.etag END,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END
        """,
        logger: logger
      )
      for try await row in generalRows {
        let value = try row.decode((String, String, String?, String?).self)
        targets.append(
          WireLinkMetadataTarget(
            canonicalKey: value.0,
            canonicalURL: value.1,
            etag: value.2,
            lastModified: value.3
          )
        )
      }
      return targets
    }
  }

  func markNotModified(
    canonicalKey: String,
    etag: String?,
    lastModified: String?,
    asOf: Date
  ) async throws {
    try await pool.query(
      """
      UPDATE wire_link_metadata_cache
      SET status = 'fresh', etag = COALESCE(\(etag), etag),
          last_modified = COALESCE(\(lastModified), last_modified), fetched_at = \(asOf),
          fresh_until = \(asOf.addingTimeInterval(86_400)),
          stale_until = \(asOf.addingTimeInterval(7 * 86_400)),
          retry_after = \(asOf.addingTimeInterval(86_400)), failure_count = 0, updated_at = \(asOf)
      WHERE canonical_key = \(canonicalKey)
      """,
      logger: logger
    )
  }

  func store(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date
  ) async throws {
    let validatedLanguageCode = WireDeclaredLanguageValidator.validatedLanguageCode(
      declaredLanguageCode: metadata.languageCode,
      title: metadata.title,
      summary: metadata.description
    )
    let homepageURL = Self.homepageURL(for: metadata.canonicalURL)
    let targetKind = WireContentQualityClassifier.targetKind(for: metadata.canonicalURL)
    let commercial = WireContentQualityClassifier.assess(
      canonicalURL: metadata.canonicalURL,
      title: metadata.title,
      summary: metadata.description,
      hasProductOfferSchema: metadata.hasProductOfferSchema,
      hasAffiliateDisclosure: metadata.hasAffiliateDisclosure
    )
    let commercialReasons = String(
      decoding: try JSONEncoder().encode(commercial.reasons.map(\.rawValue)), as: UTF8.self)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        UPDATE wire_link_metadata_cache
        SET canonical_url = \(metadata.canonicalURL), title = \(metadata.title),
            description = \(metadata.description), image_url = \(metadata.imageURL),
            site_name = \(metadata.siteName), author_name = \(metadata.authorName),
            published_at = \(metadata.publishedAt), icon_url = \(metadata.iconURL),
            etag = \(metadata.etag), last_modified = \(metadata.lastModified),
            language_code = \(validatedLanguageCode), language_checked_at = \(asOf),
            source = 'open_graph', status = 'fresh', fetched_at = \(asOf),
            fresh_until = \(asOf.addingTimeInterval(86_400)),
            stale_until = \(asOf.addingTimeInterval(7 * 86_400)),
            retry_after = \(asOf.addingTimeInterval(86_400)), failure_count = 0, updated_at = \(asOf)
        WHERE canonical_key = \(canonicalKey)
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_items
        SET title = CASE WHEN provenance ? 'standard_site' THEN title
              ELSE COALESCE(\(metadata.title), title) END,
            summary = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(summary, \(metadata.description))
              ELSE COALESCE(\(metadata.description), summary) END,
            thumbnail_url = CASE
              WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                presentation_snapshot->>'metadataSource') = 'open_graph'
                AND \(metadata.imageURL)::text IS NULL THEN NULL
              WHEN provenance ? 'standard_site' THEN COALESCE(thumbnail_url, \(metadata.imageURL))
              ELSE COALESCE(\(metadata.imageURL), thumbnail_url) END,
            source_name = CASE WHEN provenance ? 'standard_site' THEN source_name
              ELSE COALESCE(\(metadata.siteName), source_name) END,
            author_name = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(author_name, \(metadata.authorName))
              ELSE COALESCE(\(metadata.authorName), author_name) END,
            published_at = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(published_at, \(metadata.publishedAt))
              ELSE COALESCE(\(metadata.publishedAt), published_at) END,
            language_code = CASE
              WHEN provenance ? 'standard_site' AND language_code <> 'und' THEN language_code
              ELSE COALESCE(\(validatedLanguageCode), 'und') END,
            publication_homepage_url = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(publication_homepage_url, \(homepageURL))
              ELSE COALESCE(\(homepageURL), publication_homepage_url) END,
            publication_icon_url = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(publication_icon_url, \(metadata.iconURL))
              ELSE COALESCE(\(metadata.iconURL), publication_icon_url) END,
            presentation_snapshot = (presentation_snapshot - 'thumbnailUrl' - 'thumbnailSource')
              || jsonb_strip_nulls(jsonb_build_object(
              'metadataSource', CASE WHEN provenance ? 'standard_site'
                THEN presentation_snapshot->>'metadataSource' ELSE 'open_graph' END,
              'sourcePriority', CASE WHEN provenance ? 'standard_site'
                THEN presentation_snapshot->'sourcePriority' ELSE to_jsonb(300) END,
              'title', CASE WHEN provenance ? 'standard_site' THEN title
                ELSE COALESCE(\(metadata.title), title) END,
              'summary', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(summary, \(metadata.description))
                ELSE COALESCE(\(metadata.description), summary) END,
              'thumbnailUrl', CASE
                WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                  presentation_snapshot->>'metadataSource') = 'open_graph'
                  AND \(metadata.imageURL)::text IS NULL THEN NULL
                WHEN provenance ? 'standard_site' THEN COALESCE(thumbnail_url, \(metadata.imageURL))
                ELSE COALESCE(\(metadata.imageURL), thumbnail_url) END,
              'thumbnailSource', CASE
                WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                  presentation_snapshot->>'metadataSource') = 'open_graph'
                  AND \(metadata.imageURL)::text IS NULL THEN NULL
                WHEN provenance ? 'standard_site' AND thumbnail_url IS NOT NULL
                  THEN COALESCE(presentation_snapshot->'thumbnailSource',
                    to_jsonb('standard_site'::text))
                WHEN \(metadata.imageURL)::text IS NOT NULL THEN to_jsonb('open_graph'::text)
                ELSE COALESCE(presentation_snapshot->'thumbnailSource',
                  presentation_snapshot->'metadataSource') END,
              'sourceName', CASE WHEN provenance ? 'standard_site' THEN source_name
                ELSE COALESCE(\(metadata.siteName), source_name) END,
              'author', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(author_name, \(metadata.authorName))
                ELSE COALESCE(\(metadata.authorName), author_name) END,
              'publishedAt', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(published_at, \(metadata.publishedAt))
                ELSE COALESCE(\(metadata.publishedAt), published_at) END,
              'languageSource', CASE
                WHEN provenance ? 'standard_site' AND language_code <> 'und'
                  THEN COALESCE(presentation_snapshot->'languageSource', to_jsonb('unknown'::text))
                WHEN \(validatedLanguageCode)::text IS NOT NULL
                  THEN to_jsonb('content_validated_page'::text)
                WHEN provenance ? 'standard_site'
                  THEN COALESCE(presentation_snapshot->'languageSource', to_jsonb('unknown'::text))
                ELSE to_jsonb('unknown'::text)
                END,
              'homepageUrl', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(publication_homepage_url, \(homepageURL))
                ELSE COALESCE(\(homepageURL), publication_homepage_url) END,
              'iconUrl', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(publication_icon_url, \(metadata.iconURL))
                ELSE COALESCE(\(metadata.iconURL), publication_icon_url) END
            )), target_kind = CASE
              WHEN target_kind NOT IN ('external_article', 'standard_site_document') THEN target_kind
              WHEN NOT \(targetKind.canCreateItem) THEN \(targetKind.rawValue)
              WHEN provenance ? 'standard_site' THEN 'standard_site_document'
              ELSE \(targetKind.rawValue) END,
            commercial_score = GREATEST(commercial_score, \(commercial.score)),
            commercial_class = CASE
              WHEN commercial_score > \(commercial.score) THEN commercial_class
              ELSE \(commercial.classification.rawValue) END,
            commercial_reasons = CASE
              WHEN commercial_score > \(commercial.score) THEN commercial_reasons
              ELSE \(commercialReasons)::jsonb END,
            eligible = eligible AND \(targetKind.canCreateItem),
            updated_at = \(asOf)
        WHERE canonical_key = \(canonicalKey)
        """,
        logger: logger
      )
    }
  }

  func markFailure(
    canonicalKey: String,
    negative: Bool,
    asOf: Date
  ) async throws {
    let retryAfter = negative ? asOf.addingTimeInterval(6 * 3_600) : asOf.addingTimeInterval(900)
    try await pool.query(
      """
      UPDATE wire_link_metadata_cache
      SET status = \(negative ? "negative" : "retry"), retry_after = \(retryAfter),
          failure_count = failure_count + 1, updated_at = \(asOf)
      WHERE canonical_key = \(canonicalKey)
      """,
      logger: logger
    )
  }

  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? {
    let rows = try await pool.query(
      """
      WITH metadata AS (
        SELECT
          COUNT(*) FILTER (WHERE status = 'fresh' AND fresh_until > \(asOf))::bigint AS hits,
          COUNT(*) FILTER (WHERE fresh_until <= \(asOf) AND stale_until > \(asOf))::bigint AS stale,
          COUNT(*) FILTER (WHERE status IN ('pending', 'fetching', 'retry', 'negative'))::bigint AS misses,
          COUNT(*) FILTER (WHERE status IN ('retry', 'negative', 'failed'))::bigint AS failures,
          COALESCE(EXTRACT(EPOCH FROM (\(asOf) - MIN(updated_at) FILTER (
            WHERE status IN ('retry', 'negative', 'failed')))), 0)::double precision AS failure_age
        FROM wire_link_metadata_cache
      ), eligible_people AS (
        SELECT COUNT(*)::bigint AS count FROM (
          SELECT subject_did FROM wire_item_mentions
          WHERE expires_at > \(asOf)
          GROUP BY subject_did
          HAVING COUNT(DISTINCT canonical_key) >= 2
             AND COUNT(DISTINCT speaker_key_hash) >= 3
        ) eligible
      ), fresh_people AS (
        SELECT COUNT(*)::bigint AS count FROM wire_talked_accounts
        WHERE status = 'fresh' AND expires_at > \(asOf)
      )
      SELECT metadata.hits, metadata.stale, metadata.misses, metadata.failures,
             metadata.failure_age, eligible_people.count, fresh_people.count
      FROM metadata, eligible_people, fresh_people
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((Int64, Int64, Int64, Int64, Double, Int64, Int64).self)
      return WireEnrichmentHealthSnapshot(
        metadataHitCount: Int(value.0), metadataStaleCount: Int(value.1),
        metadataMissCount: Int(value.2), metadataFailureCount: Int(value.3),
        oldestFailureAgeSeconds: value.4, peopleEligibleCount: Int(value.5),
        peopleFreshCount: Int(value.6)
      )
    }
    return nil
  }

  private static func homepageURL(for articleURL: String) -> String? {
    guard let url = URL(string: articleURL), let scheme = url.scheme, let host = url.host else {
      return nil
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.url?.absoluteString
  }
}
