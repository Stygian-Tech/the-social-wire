-- User-action ordering and maintenance revisions are independent in v2.
-- V1's effective revision is its action sequence; the row lock serializes both.
ALTER TABLE appview_pds_read_state_authority
  ADD COLUMN manifest_revision BIGINT NOT NULL DEFAULT 0
  CHECK (manifest_revision BETWEEN 0 AND 9007199254740991);
UPDATE appview_pds_read_state_authority SET manifest_revision = last_sequence
WHERE manifest IS NOT NULL;
