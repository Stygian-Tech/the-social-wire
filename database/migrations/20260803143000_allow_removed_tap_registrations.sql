-- A repository can be removed before this environment has recorded its registration.
-- Keep registered_at nullable so the durable boundary can represent that state.
ALTER TABLE appview_tap_repository_registrations
  ALTER COLUMN registered_at DROP NOT NULL;
