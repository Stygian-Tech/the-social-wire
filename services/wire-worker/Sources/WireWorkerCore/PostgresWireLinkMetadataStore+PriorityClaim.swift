import Foundation
import PostgresNIO

extension PostgresWireLinkMetadataStore {
  static func metadataPriorityClaimQuery(asOf: Date, limit: Int, scheduling: Bool) -> PostgresQuery {
    if scheduling {
      return """
        WITH due AS (
          SELECT cache.canonical_key
          FROM wire_metadata_priority_work item
          JOIN wire_link_metadata_cache cache ON cache.canonical_key = item.canonical_key
          WHERE item.item_present AND item.cache_present
            AND EXISTS (
              SELECT 1 FROM wire_items authoritative
              WHERE authoritative.canonical_key = item.canonical_key
                AND authoritative.language_code = 'und' AND authoritative.eligible
                AND authoritative.expires_at > \(asOf)
                AND authoritative.target_kind IN ('external_article', 'standard_site_document')
                AND authoritative.commercial_class <> 'probable_ad'
                AND authoritative.source_confidence >= 0.25
            )
            AND item.language_code = 'und'
            AND item.eligible = TRUE AND item.expires_at > \(asOf)
            AND item.target_kind IN ('external_article', 'standard_site_document')
            AND item.commercial_class <> 'probable_ad'
            AND item.source_confidence >= 0.25
            AND item.language_checked_at IS NULL AND cache.language_checked_at IS NULL
            AND cache.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (cache.retry_after <= \(asOf)
                AND (cache.fresh_until IS NULL OR cache.fresh_until <= \(asOf)))
              OR (cache.source = 'open_graph' AND cache.status IN ('fresh', 'stale')
                AND cache.language_checked_at IS NULL)
            )
            AND item.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND ((item.retry_after <= \(asOf) AND (item.fresh_until IS NULL OR item.fresh_until <= \(asOf)))
              OR (item.source = 'open_graph' AND item.status IN ('fresh', 'stale')
                AND item.language_checked_at IS NULL))
          ORDER BY item.last_signal_at DESC NULLS LAST, item.retry_after, item.canonical_key
          FOR UPDATE OF cache SKIP LOCKED
          LIMIT \(limit)
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
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END,
          cache.retry_after
        """
    }
    return """
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
          LIMIT \(limit)
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
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END,
          cache.retry_after
        """
  }
}
