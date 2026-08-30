-- Page-declared languages are hints, not authority. Keep an exact locale only
-- when bounded title/summary content corroborates the declared language.
WITH language_lexicon(language_code, words) AS (
  VALUES
    ('de', ARRAY['aber','auf','das','der','die','ein','eine','für','ist','mit','nicht','und','von','wie','zu']),
    ('en', ARRAY['and','are','as','at','by','for','from','how','in','is','new','of','on','the','this','to','what','when','why','will','with']),
    ('es', ARRAY['como','con','de','del','el','en','es','la','las','los','para','por','que','una','y']),
    ('fr', ARRAY['avec','comment','dans','de','des','du','en','est','français','la','le','les','pour','sur','une']),
    ('it', ARRAY['che','come','con','da','del','della','di','e','gli','il','in','la','le','per','una']),
    ('nl', ARRAY['als','de','een','en','het','hoe','in','is','met','op','te','van','voor']),
    ('pt', ARRAY['como','com','da','de','do','dos','em','e','não','o','os','para','por','que','uma']),
    ('tl', ARRAY['ang','apektado','habagat','lugar','malawakang','mga','na','nagsagawa','ng','para','sa','ulat']),
    ('tr', ARRAY['bir','bu','da','de','ile','için','mi','nasıl','ve'])
), checked AS (
  SELECT cache.canonical_key,
    lower(split_part(replace(cache.language_code, '_', '-'), '-', 1)) AS declared,
    lower(concat_ws(' ', cache.title, cache.description)) AS evidence,
    regexp_split_to_array(
      lower(concat_ws(' ', cache.title, cache.description)), '[^[:alpha:]]+'
    ) AS tokens
  FROM wire_link_metadata_cache cache
  WHERE cache.language_checked_at IS NOT NULL
), scored AS (
  SELECT checked.*,
    COALESCE((
      SELECT COUNT(*)::integer
      FROM language_lexicon declared_lexicon,
        unnest(declared_lexicon.words) word
      WHERE declared_lexicon.language_code = checked.declared
        AND word = ANY(checked.tokens)
    ), 0) AS declared_score,
    COALESCE((
      SELECT MAX(other_score)
      FROM (
        SELECT COUNT(*)::integer AS other_score
        FROM language_lexicon other_lexicon,
          unnest(other_lexicon.words) word
        WHERE other_lexicon.language_code <> checked.declared
          AND word = ANY(checked.tokens)
        GROUP BY other_lexicon.language_code
      ) scores
    ), 0) AS strongest_contradiction
  FROM checked
), validated AS (
  SELECT canonical_key,
    CASE
      WHEN declared = 'ja' AND evidence ~ '[ぁ-ヿ一-龯]' THEN declared
      WHEN declared = 'zh' AND evidence ~ '[一-龯]' AND evidence !~ '[ぁ-ヿ]' THEN declared
      WHEN declared = 'ko' AND evidence ~ '[가-힯]' THEN declared
      WHEN declared IN ('ru', 'uk') AND evidence ~ '[Ѐ-ӿ]' THEN declared
      WHEN declared IN ('ar', 'fa') AND evidence ~ '[؀-ۿݐ-ݿ]' THEN declared
      WHEN declared = 'he' AND evidence ~ '[֐-׿]' THEN declared
      WHEN declared = 'hi' AND evidence ~ '[ऀ-ॿ]' THEN declared
      WHEN declared = 'bn' AND evidence ~ '[ঀ-৿]' THEN declared
      WHEN declared = 'th' AND evidence ~ '[฀-๿]' THEN declared
      WHEN declared IN (SELECT language_code FROM language_lexicon)
        AND evidence !~ '[ぁ-ヿ一-龯가-힯Ѐ-ӿ؀-ۿݐ-ݿ֐-׿ऀ-ॿঀ-৿฀-๿]'
        AND declared_score >= 2
        AND declared_score >= strongest_contradiction
      THEN declared
      ELSE NULL
    END AS language_code
  FROM scored
)
UPDATE wire_link_metadata_cache cache
SET language_code = validated.language_code, updated_at = NOW()
FROM validated
WHERE cache.canonical_key = validated.canonical_key
  AND cache.language_code IS DISTINCT FROM validated.language_code;

UPDATE wire_items item
SET language_code = COALESCE(cache.language_code, 'und'),
    presentation_snapshot = jsonb_set(
      COALESCE(item.presentation_snapshot, '{}'::jsonb),
      '{languageSource}',
      to_jsonb(CASE WHEN cache.language_code IS NULL
        THEN 'unknown'::text ELSE 'content_validated_page'::text END),
      TRUE
    ),
    updated_at = NOW()
FROM wire_link_metadata_cache cache
WHERE cache.canonical_key = item.canonical_key
  AND cache.language_checked_at IS NOT NULL
  AND NOT (item.provenance ? 'standard_site')
  AND (
    item.language_code IS DISTINCT FROM COALESCE(cache.language_code, 'und')
    OR item.presentation_snapshot->>'languageSource' IS DISTINCT FROM
      CASE WHEN cache.language_code IS NULL
        THEN 'unknown'::text ELSE 'content_validated_page'::text END
  );

COMMENT ON COLUMN wire_link_metadata_cache.language_code IS
  'Page-declared language retained only when bounded title/summary content corroborates it.';
