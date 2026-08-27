-- The Wire inbox is a high-churn queue. Percentage-based defaults let hundreds
-- of thousands of dead row/index versions accumulate before autovacuum runs,
-- which makes each FIFO claim walk stale index entries and fetch heap pages.
-- Keep maintenance proportional to queue churn instead of total backlog size.

ALTER TABLE wire_ingestion_inbox SET (
  autovacuum_vacuum_scale_factor = 0.005,
  autovacuum_vacuum_threshold = 5000,
  autovacuum_analyze_scale_factor = 0.0025,
  autovacuum_analyze_threshold = 2500,
  autovacuum_vacuum_cost_limit = 2000,
  autovacuum_vacuum_cost_delay = 2
);

ANALYZE wire_ingestion_inbox;
