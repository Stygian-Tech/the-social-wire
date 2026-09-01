-- Seed the launch-time local safety label for explicit content already present in the
-- rebuildable Wire projection. New and updated items use the equivalent Swift classifier.
WITH explicit_items AS (
  SELECT item.canonical_key, item.expires_at
  FROM wire_items item
  WHERE LOWER(item.source_domain) = '3movs.com'
    OR LOWER(item.source_domain) LIKE '%.3movs.com'
    OR (
      (LOWER(item.source_domain) = 'donmai.us'
        OR LOWER(item.source_domain) LIKE '%.donmai.us')
      AND LOWER(CONCAT_WS(' ', item.title, item.summary, item.topic_keys::text))
        ~ '(^|[^[:alnum:]])(bdsm|cock|cocks|fuck|fucking|gagged|hardcore|milf|naked|pussy|pussies|stepsis|stepbrother|breast|breasts|boob|boobs|groin|nude)([^[:alnum:]]|$)'
    )
    OR LOWER(CONCAT_WS(' ', item.title, item.summary, item.topic_keys::text))
      ~ '(^|[^[:alnum:]])(blowjob|blowjobs|cumshot|cumshots|deepthroat|gangbang|gangbangs|hardcoreporn|hentai|pornographic)([^[:alnum:]]|$)'
    OR (
      LOWER(CONCAT_WS(' ', item.title, item.summary, item.topic_keys::text))
        ~ '(^|[^[:alnum:]])(bdsm|cock|cocks|fuck|fucking|gagged|hardcore|milf|naked|pussy|pussies|stepsis|stepbrother)([^[:alnum:]]|$)'
      AND (
        SELECT COUNT(DISTINCT token)
        FROM REGEXP_SPLIT_TO_TABLE(
          LOWER(CONCAT_WS(' ', item.title, item.summary, item.topic_keys::text)),
          '[^[:alnum:]]+'
        ) AS token
        WHERE token IN (
          'bdsm', 'cock', 'cocks', 'fuck', 'fucking', 'gagged', 'hardcore', 'milf',
          'naked', 'pussy', 'pussies', 'stepsis', 'stepbrother'
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
