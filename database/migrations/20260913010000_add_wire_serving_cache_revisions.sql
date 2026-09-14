-- Append opaque row-version tokens to the existing granted serving views.
-- Readers still recheck the security-barrier eligibility predicates on every hit.
-- These short-lived cache tokens are not durable identifiers or ordering clocks.
-- Token-only column reads avoid detoasting titles, summaries and profile bodies.
CREATE OR REPLACE VIEW wire_serving.items
WITH (security_barrier = TRUE) AS
SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
  item.summary, item.published_at, item.thumbnail_url, item.source_name,
  item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url, item.language_code,
  item.xmin::text || ':' || item.ctid::text AS cache_revision
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
  item.publication_homepage_url, item.publication_icon_url, item.language_code,
  item.xmin::text || ':' || item.ctid::text || ':' || ranked.xmin::text || ':' || ranked.ctid::text AS cache_revision
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

CREATE OR REPLACE VIEW wire_serving.edition_generations AS
SELECT
  edition.generation_id,
  edition.algorithm_version,
  edition.language_bucket,
  edition.continuation_ordinal,
  generation.generated_at,
  generation.expires_at,
  edition.xmin::text || ':' || edition.ctid::text AS cache_revision
FROM wire_edition_generations AS edition
JOIN wire_rank_generations AS generation
  ON generation.generation_id = edition.generation_id
WHERE generation.feed_key = 'wire'
  AND generation.status IN ('committed', 'superseded');

CREATE OR REPLACE VIEW wire_serving.edition_modules AS
SELECT
  module.generation_id,
  module.module_key,
  module.module_kind,
  module.title,
  module.position,
  module.reason_code,
  module.publication_key,
  module.publication_name,
  module.publication_domain,
  module.publication_homepage_url,
  module.publication_icon_url,
  module.xmin::text || ':' || module.ctid::text AS cache_revision
FROM wire_edition_modules AS module
JOIN wire_serving.edition_generations AS generation
  ON generation.generation_id = module.generation_id;

CREATE OR REPLACE VIEW wire_serving.edition_module_items
WITH (security_barrier = TRUE) AS
SELECT
  module_item.generation_id,
  module_item.module_key,
  module_item.position AS module_position,
  ranked.canonical_key,
  ranked.canonical_url,
  ranked.representative_uri,
  ranked.title,
  ranked.summary,
  ranked.published_at,
  ranked.thumbnail_url,
  ranked.source_name,
  ranked.source_domain,
  ranked.publication_id,
  ranked.author_name,
  ranked.provenance,
  ranked.author_key,
  ranked.reason_codes,
  ranked.publication_key,
  ranked.publication_homepage_url,
  ranked.publication_icon_url,
  ranked.cache_revision || ':' || module_item.xmin::text || ':' || module_item.ctid::text AS cache_revision
FROM wire_edition_module_items AS module_item
JOIN wire_serving.ranked_items AS ranked
  ON ranked.generation_id = module_item.generation_id
 AND ranked.canonical_key = module_item.canonical_key;

CREATE OR REPLACE VIEW wire_serving.edition_talked_accounts
WITH (security_barrier = TRUE) AS
SELECT
  selected.generation_id,
  selected.position,
  profile.subject_did,
  profile.handle,
  profile.display_name,
  profile.avatar_url,
  profile.description,
  profile.xmin::text || ':' || profile.ctid::text || ':' || selected.xmin::text || ':' || selected.ctid::text AS cache_revision
FROM wire_edition_talked_accounts AS selected
JOIN wire_talked_accounts AS profile
  ON profile.subject_did = selected.subject_did
WHERE profile.status = 'fresh'
  AND profile.expires_at > CURRENT_TIMESTAMP;

