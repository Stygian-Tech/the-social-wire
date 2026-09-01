-- Expand the launch-time base labeler for explicit publishers and high-confidence
-- combinations observed after the first Production materialization. The Swift
-- classifier applies the same rules to new and updated items.
WITH candidate_text AS (
  SELECT
    item.canonical_key,
    item.expires_at,
    LOWER(item.source_domain) AS source_domain,
    LOWER(CONCAT_WS(' ', item.title, item.summary, item.topic_keys::text)) AS text
  FROM wire_items item
), explicit_items AS (
  SELECT candidate.canonical_key, candidate.expires_at
  FROM candidate_text candidate
  WHERE candidate.source_domain IN ('3movs.com', '3dporndude.com', 'mengem.com')
    OR candidate.source_domain LIKE '%.3movs.com'
    OR candidate.source_domain LIKE '%.3dporndude.com'
    OR candidate.source_domain LIKE '%.mengem.com'
    OR (
      SELECT COUNT(DISTINCT token)
      FROM REGEXP_SPLIT_TO_TABLE(candidate.text, '[^[:alnum:]]+') AS token
      WHERE token IN ('cock', 'cocks', 'dick', 'dicks', 'pussy', 'pussies', 'tit', 'tits')
    ) >= 2
    OR (
      candidate.text
        ~ '(^|[^[:alnum:]])(cock|cocks|dick|dicks|pussy|pussies|tit|tits)([^[:alnum:]]|$)'
      AND (
        SELECT COUNT(DISTINCT token)
        FROM REGEXP_SPLIT_TO_TABLE(candidate.text, '[^[:alnum:]]+') AS token
        WHERE token IN (
          'daddy', 'dominating', 'fetish', 'hardcore', 'horny', 'porno', 'porn', 'steamy'
        )
      ) >= 2
    )
)
INSERT INTO wire_labels
  (canonical_key, label_key, label_value, source, confidence, applied_at, expires_at)
SELECT canonical_key, 'moderation', 'adult',
       'app.thesocialwire.base-content-labeler', 1, NOW(), expires_at
FROM explicit_items
ON CONFLICT (canonical_key, label_key, source) DO UPDATE SET
  label_value = EXCLUDED.label_value,
  confidence = EXCLUDED.confidence,
  applied_at = EXCLUDED.applied_at,
  expires_at = EXCLUDED.expires_at;
