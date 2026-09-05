-- Hosted Postgres already preloads the library. Creating the extension exposes
-- its accumulated counters; never reset the shared baseline during rollout.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
