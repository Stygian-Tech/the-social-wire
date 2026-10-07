package wireworkercore

// Fixed SQL preserves the canonical worker claim, priority, and source precedence contracts.

const metadataGeneralSQL = `WITH due AS (
          SELECT canonical_key
          FROM wire_link_metadata_cache
          WHERE status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (retry_after <= $1 AND (fresh_until IS NULL OR fresh_until <= $1))
              OR (source = 'open_graph' AND status IN ('fresh', 'stale')
                AND language_checked_at IS NULL)
            )
          ORDER BY language_checked_at NULLS FIRST, retry_after, canonical_key
          FOR UPDATE SKIP LOCKED
          LIMIT $2
        )
        UPDATE wire_link_metadata_cache cache
        SET status = 'fetching', retry_after = $3,
            fresh_until = CASE WHEN cache.language_checked_at IS NULL
              THEN LEAST(COALESCE(cache.fresh_until, $1), $1)
              ELSE cache.fresh_until END,
            updated_at = $1
        FROM due
        WHERE cache.canonical_key = due.canonical_key
        RETURNING cache.canonical_key, cache.canonical_url,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.etag END,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END,
          cache.retry_after`

const metadataRenewSQL = `UPDATE wire_link_metadata_cache
      SET retry_after = GREATEST($1, retry_after + INTERVAL '1 second'),
          updated_at = $2
      WHERE canonical_key = $3
        AND status = 'fetching' AND retry_after = $4
      RETURNING canonical_key, canonical_url,
        CASE WHEN language_checked_at IS NULL THEN NULL ELSE etag END,
        CASE WHEN language_checked_at IS NULL THEN NULL ELSE last_modified END,
        retry_after`

const metadataNotModifiedSQL = `UPDATE wire_link_metadata_cache
      SET status = 'fresh', etag = COALESCE($1, etag),
          last_modified = COALESCE($2, last_modified), fetched_at = $3,
          fresh_until = $4,
          stale_until = $5,
          retry_after = $4, failure_count = 0, updated_at = $3
      WHERE canonical_key = $6
        AND ($7::timestamptz IS NULL OR (
          status = 'fetching' AND retry_after = $7::timestamptz
          AND retry_after > $3))`

const metadataCacheUpdateSQL = `UPDATE wire_link_metadata_cache
        SET canonical_url = $1, title = $2,
            description = $3, image_url = $4,
            site_name = $5, author_name = $6,
            published_at = $7, icon_url = $8,
            etag = $9, last_modified = $10,
            language_code = $11, language_checked_at = $12,
            source = 'open_graph', status = 'fresh', fetched_at = $12,
            fresh_until = $13,
            stale_until = $14,
            retry_after = $13, failure_count = 0, updated_at = $12
        WHERE canonical_key = $15
        AND ($16::timestamptz IS NULL OR (
          status = 'fetching' AND retry_after = $16::timestamptz
          AND retry_after > $12))
        RETURNING canonical_key`

const metadataItemUpdateSQL = `UPDATE wire_items
        SET title = CASE WHEN provenance ? 'standard_site' THEN title
              ELSE COALESCE($1, title) END,
            summary = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(summary, $2)
              ELSE COALESCE($2, summary) END,
            thumbnail_url = CASE
              WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                presentation_snapshot->>'metadataSource') = 'open_graph'
                AND $3::text IS NULL THEN NULL
              WHEN provenance ? 'standard_site' THEN COALESCE(thumbnail_url, $3)
              ELSE COALESCE($3, thumbnail_url) END,
            source_name = CASE WHEN provenance ? 'standard_site' THEN source_name
              ELSE COALESCE($4, source_name) END,
            author_name = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(author_name, $5)
              ELSE COALESCE($5, author_name) END,
            published_at = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(published_at, $6)
              ELSE COALESCE($6, published_at) END,
            language_code = CASE
              WHEN provenance ? 'standard_site' AND language_code <> 'und' THEN language_code
              ELSE COALESCE($7, 'und') END,
            publication_homepage_url = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(publication_homepage_url, $8)
              ELSE COALESCE($8, publication_homepage_url) END,
            publication_icon_url = CASE WHEN provenance ? 'standard_site'
              THEN COALESCE(publication_icon_url, $9)
              ELSE COALESCE($9, publication_icon_url) END,
            presentation_snapshot = (presentation_snapshot - 'thumbnailUrl' - 'thumbnailSource')
              || jsonb_strip_nulls(jsonb_build_object(
              'metadataSource', CASE WHEN provenance ? 'standard_site'
                THEN presentation_snapshot->>'metadataSource' ELSE 'open_graph' END,
              'sourcePriority', CASE WHEN provenance ? 'standard_site'
                THEN presentation_snapshot->'sourcePriority' ELSE to_jsonb(300) END,
              'title', CASE WHEN provenance ? 'standard_site' THEN title
                ELSE COALESCE($1, title) END,
              'summary', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(summary, $2)
                ELSE COALESCE($2, summary) END,
              'thumbnailUrl', CASE
                WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                  presentation_snapshot->>'metadataSource') = 'open_graph'
                  AND $3::text IS NULL THEN NULL
                WHEN provenance ? 'standard_site' THEN COALESCE(thumbnail_url, $3)
                ELSE COALESCE($3, thumbnail_url) END,
              'thumbnailSource', CASE
                WHEN COALESCE(presentation_snapshot->>'thumbnailSource',
                  presentation_snapshot->>'metadataSource') = 'open_graph'
                  AND $3::text IS NULL THEN NULL
                WHEN provenance ? 'standard_site' AND thumbnail_url IS NOT NULL
                  THEN COALESCE(presentation_snapshot->'thumbnailSource',
                    to_jsonb('standard_site'::text))
                WHEN $3::text IS NOT NULL THEN to_jsonb('open_graph'::text)
                ELSE COALESCE(presentation_snapshot->'thumbnailSource',
                  presentation_snapshot->'metadataSource') END,
              'sourceName', CASE WHEN provenance ? 'standard_site' THEN source_name
                ELSE COALESCE($4, source_name) END,
              'author', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(author_name, $5)
                ELSE COALESCE($5, author_name) END,
              'publishedAt', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(published_at, $6)
                ELSE COALESCE($6, published_at) END,
              'languageSource', CASE
                WHEN provenance ? 'standard_site' AND language_code <> 'und'
                  THEN COALESCE(presentation_snapshot->'languageSource', to_jsonb('unknown'::text))
                WHEN $7::text IS NOT NULL
                  THEN to_jsonb('content_validated_page'::text)
                WHEN provenance ? 'standard_site'
                  THEN COALESCE(presentation_snapshot->'languageSource', to_jsonb('unknown'::text))
                ELSE to_jsonb('unknown'::text)
                END,
              'homepageUrl', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(publication_homepage_url, $8)
                ELSE COALESCE($8, publication_homepage_url) END,
              'iconUrl', CASE WHEN provenance ? 'standard_site'
                THEN COALESCE(publication_icon_url, $9)
                ELSE COALESCE($9, publication_icon_url) END
            )), target_kind = CASE
              WHEN target_kind NOT IN ('external_article', 'standard_site_document') THEN target_kind
              WHEN NOT $10 THEN $11
              WHEN provenance ? 'standard_site' THEN 'standard_site_document'
              ELSE $11 END,
            commercial_score = GREATEST(commercial_score, $12),
            commercial_class = CASE
              WHEN commercial_score > $12 THEN commercial_class
              ELSE $13 END,
            commercial_reasons = CASE
              WHEN commercial_score > $12 THEN commercial_reasons
              ELSE $14::jsonb END,
            eligible = eligible AND $10,
            updated_at = $15
        WHERE canonical_key = $16`

const metadataFailureSQL = `UPDATE wire_link_metadata_cache
      SET status = $1, retry_after = $2,
          failure_count = failure_count + 1, updated_at = $3
      WHERE canonical_key = $4
        AND ($5::timestamptz IS NULL OR (
          status = 'fetching' AND retry_after = $5::timestamptz
          AND retry_after > $3))`

const metadataPrioritySQL = `WITH due AS (
          SELECT cache.canonical_key
          FROM wire_items item
          JOIN wire_link_metadata_cache cache ON cache.canonical_key = item.canonical_key
          WHERE item.language_code = 'und'
            AND item.eligible = TRUE AND item.expires_at > $1
            AND item.target_kind IN ('external_article', 'standard_site_document')
            AND item.commercial_class <> 'probable_ad'
            AND item.source_confidence >= 0.25
            AND cache.language_checked_at IS NULL
            AND cache.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (cache.retry_after <= $1
                AND (cache.fresh_until IS NULL OR cache.fresh_until <= $1))
              OR (cache.source = 'open_graph' AND cache.status IN ('fresh', 'stale')
                AND cache.language_checked_at IS NULL)
            )
          ORDER BY item.last_signal_at DESC NULLS LAST, cache.retry_after, cache.canonical_key
          FOR UPDATE OF cache SKIP LOCKED
          LIMIT $2
        )
        UPDATE wire_link_metadata_cache cache
        SET status = 'fetching', retry_after = $3,
            fresh_until = CASE WHEN cache.language_checked_at IS NULL
              THEN LEAST(COALESCE(cache.fresh_until, $1), $1)
              ELSE cache.fresh_until END,
            updated_at = $1
        FROM due
        WHERE cache.canonical_key = due.canonical_key
        RETURNING cache.canonical_key, cache.canonical_url,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.etag END,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END,
          cache.retry_after`
