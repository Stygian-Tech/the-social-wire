-- Podcast metadata and durable private listener state; public source records remain on PDS.
CREATE TABLE IF NOT EXISTS podcast_shows (
 id text PRIMARY KEY, feed_url text UNIQUE, source_kind text NOT NULL CHECK(source_kind IN ('rss','atproto')),
 source_uri text UNIQUE, show_json jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS podcast_episodes (
 id text PRIMARY KEY, show_id text NOT NULL REFERENCES podcast_shows(id), guid text,
 episode_json jsonb NOT NULL, published_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS podcast_episodes_show_page ON podcast_episodes(show_id,published_at DESC,id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS podcast_episodes_guid ON podcast_episodes(show_id,guid) WHERE guid IS NOT NULL;
CREATE TABLE IF NOT EXISTS podcast_aliases (
 alias text PRIMARY KEY, canonical_id text NOT NULL, entity_kind text NOT NULL CHECK(entity_kind IN ('show','episode'))
);
CREATE TABLE IF NOT EXISTS podcast_subscriptions (
 viewer_did text NOT NULL, show_id text NOT NULL REFERENCES podcast_shows(id), source_uri text NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(viewer_did,show_id)
);
CREATE INDEX IF NOT EXISTS podcast_subscriptions_show ON podcast_subscriptions(show_id);
CREATE TABLE IF NOT EXISTS podcast_viewer_state (
 viewer_did text PRIMARY KEY, revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 state_json jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS podcast_jobs (
 id uuid PRIMARY KEY, viewer_did text, episode_id text REFERENCES podcast_episodes(id),
 kind text NOT NULL CHECK(kind IN ('bridge','silence','clip','transcript','cleanup')),
 status text NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','complete','failed')),
 dedupe_key text UNIQUE NOT NULL, payload_json jsonb NOT NULL, result_json jsonb,
 attempts integer NOT NULL DEFAULT 0, available_at timestamptz NOT NULL DEFAULT now(),
 lease_until timestamptz, worker_id text, error text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS podcast_jobs_claim ON podcast_jobs(status,available_at,lease_until);
CREATE TABLE IF NOT EXISTS podcast_clips (
 id uuid PRIMARY KEY, viewer_did text NOT NULL, episode_id text NOT NULL REFERENCES podcast_episodes(id),
 clip_json jsonb NOT NULL, published_uri text UNIQUE, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS podcast_clips_viewer ON podcast_clips(viewer_did,updated_at DESC);
