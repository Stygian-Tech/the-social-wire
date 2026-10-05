-- Private feeds are durable viewer-owned data, never public catalog or bridge projections.
CREATE TABLE IF NOT EXISTS podcast_private_shows (
 viewer_did text NOT NULL, id text NOT NULL, feed_hash text NOT NULL,
 feed_data text NOT NULL, show_data text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(viewer_did,id), UNIQUE(viewer_did,feed_hash)
);
CREATE TABLE IF NOT EXISTS podcast_private_episodes (
 viewer_did text NOT NULL, id text NOT NULL, show_id text NOT NULL,
 episode_data text NOT NULL, published_at timestamptz NOT NULL,
 PRIMARY KEY(viewer_did,id),
 FOREIGN KEY(viewer_did,show_id) REFERENCES podcast_private_shows(viewer_did,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS podcast_private_episodes_page
 ON podcast_private_episodes(viewer_did,show_id,published_at DESC,id DESC);
