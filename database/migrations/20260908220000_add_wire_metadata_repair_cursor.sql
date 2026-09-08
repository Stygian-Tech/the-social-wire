-- Only the repair position is durable; losing it may repeat a bounded page but
-- must never affect ingestion recovery or metadata claim ownership.
CREATE TABLE IF NOT EXISTS wire_metadata_repair_cursor (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  canonical_key TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO wire_metadata_repair_cursor (singleton) VALUES (TRUE)
ON CONFLICT (singleton) DO NOTHING;
