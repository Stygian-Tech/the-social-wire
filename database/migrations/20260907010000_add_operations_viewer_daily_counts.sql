-- Aggregate observations only: never persist viewer identities or invent historic counts.
-- Operations refreshes today's UTC sample hourly and retains today plus 89 prior dates.
CREATE TABLE IF NOT EXISTS operations_viewer_daily_counts (
  environment TEXT NOT NULL,
  snapshot_day DATE NOT NULL,
  known_viewers BIGINT NOT NULL CHECK (known_viewers >= 0),
  active_viewers_7d BIGINT NOT NULL CHECK (active_viewers_7d >= 0),
  active_viewers_30d BIGINT NOT NULL CHECK (active_viewers_30d >= active_viewers_7d),
  observed_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, snapshot_day),
  CHECK (known_viewers >= active_viewers_30d),
  CHECK (snapshot_day = (observed_at AT TIME ZONE 'UTC')::date)
);
