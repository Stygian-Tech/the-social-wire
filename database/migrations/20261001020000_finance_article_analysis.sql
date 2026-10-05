-- Rebuildable article resolution belongs to Projection Pool. Coordinator only reads
-- exact source/catalog/resolver matches when constructing immutable generations.
CREATE TABLE finance_article_analysis (
  canonical_key text PRIMARY KEY REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  source_fingerprint text NOT NULL,
  catalog_revision text NOT NULL,
  resolver_version text NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  analyzed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX finance_article_analysis_expiry ON finance_article_analysis (expires_at);
COMMENT ON TABLE finance_article_analysis IS
  'Private rebuildable Finance article analysis; no prices or viewer selections. Projection Pool writes, Coordinator reads.';
