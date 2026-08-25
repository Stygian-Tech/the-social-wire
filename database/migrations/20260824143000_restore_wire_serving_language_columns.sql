-- The commercial-quality migration recreated these views without language_code.
-- Keep the serving boundary language-aware so localized editions cannot silently
-- lose the field used to validate and diagnose their corpus.

CREATE OR REPLACE VIEW wire_serving.items
WITH (security_barrier = TRUE) AS
SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
  item.summary, item.published_at, item.thumbnail_url, item.source_name,
  item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url, item.language_code
FROM wire_items AS item
WHERE item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));

CREATE OR REPLACE VIEW wire_serving.ranked_items
WITH (security_barrier = TRUE) AS
SELECT ranked.generation_id, ranked.position, item.canonical_key, item.canonical_url,
  item.representative_uri, item.title, item.summary, item.published_at, item.thumbnail_url,
  item.source_name, item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key, ranked.reason_codes,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url, item.language_code
FROM wire_ranked_items AS ranked
JOIN wire_rank_generations AS generation ON generation.generation_id = ranked.generation_id
JOIN wire_items AS item ON item.canonical_key = ranked.canonical_key
WHERE generation.feed_key = 'wire' AND generation.status IN ('committed', 'superseded')
  AND item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));
