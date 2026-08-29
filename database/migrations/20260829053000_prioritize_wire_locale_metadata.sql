-- socialwire:transaction=off

SET lock_timeout = '5s';
SET statement_timeout = '30min';

CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_items_unclassified_metadata_priority_idx
  ON wire_items (last_signal_at DESC NULLS LAST, canonical_key)
  WHERE language_code = 'und'
    AND eligible = TRUE
    AND target_kind IN ('external_article', 'standard_site_document')
    AND commercial_class <> 'probable_ad'
    AND source_confidence >= 0.25;

RESET statement_timeout;
RESET lock_timeout;

COMMENT ON INDEX wire_items_unclassified_metadata_priority_idx IS
  'Prioritizes current unclassified Wire stories for bounded metadata language recovery.';
