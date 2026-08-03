ALTER TABLE appview_backfill_jobs
  ADD COLUMN IF NOT EXISTS failure_reason TEXT;
