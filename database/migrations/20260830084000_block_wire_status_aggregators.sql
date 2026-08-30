UPDATE wire_items
SET target_kind = 'operational_status', eligible = FALSE, updated_at = NOW()
WHERE lower(source_domain) = 'fedilist.com'
  OR lower(source_domain) LIKE '%.fedilist.com';

COMMENT ON COLUMN wire_items.target_kind IS
  'Canonical target admission kind; dedicated status hosts and status aggregators are retained for audit but never served.';
