-- Rebuildable creator inventory and observed engagement. Never reader read-state.
CREATE TABLE creator_analytics_items (
 author_did text NOT NULL, subject_uri text NOT NULL, item_json jsonb NOT NULL,
 refreshed_at timestamptz NOT NULL, PRIMARY KEY(author_did,subject_uri)
);
CREATE TABLE creator_analytics_refresh (
 author_did text PRIMARY KEY, refreshed_at timestamptz NOT NULL, inventory_complete boolean NOT NULL
);
CREATE TABLE creator_analytics_snapshots (
 author_did text NOT NULL, subject_uri text NOT NULL, day date NOT NULL,
 likes integer NOT NULL, replies integer NOT NULL, reposts integer NOT NULL, quotes integer NOT NULL,
 PRIMARY KEY(author_did,subject_uri,day)
);
-- Daily keyed pseudonyms, no raw viewer DID, IP, user agent, or destination URL.
CREATE TABLE creator_analytics_events (
 author_did text NOT NULL, subject_uri text NOT NULL, day date NOT NULL,
 viewer_key text NOT NULL, event text NOT NULL CHECK(event IN ('impression','view','outbound_click')),
 surface text NOT NULL CHECK(surface IN ('social-feed','article-feed','post-viewer','article-reader','messages')),
 PRIMARY KEY(subject_uri,day,viewer_key,event)
);
CREATE INDEX creator_analytics_events_budget ON creator_analytics_events(day,viewer_key);
CREATE TABLE creator_analytics_tracking (
 author_did text NOT NULL, subject_uri text NOT NULL, day date NOT NULL,
 impressions integer NOT NULL DEFAULT 0, views integer NOT NULL DEFAULT 0, outbound_clicks integer NOT NULL DEFAULT 0,
 PRIMARY KEY(author_did,subject_uri,day)
);
COMMENT ON TABLE creator_analytics_events IS 'Authenticated Social Wire observations, daily subject/viewer/event deduplication. Pseudonymous rows become eligible for hourly bounded deletion after 30 days; aggregates/snapshots after 90 days.';
CREATE INDEX creator_analytics_snapshots_expiry ON creator_analytics_snapshots(day);
CREATE INDEX creator_analytics_tracking_expiry ON creator_analytics_tracking(day);
CREATE INDEX creator_analytics_items_expiry ON creator_analytics_items(refreshed_at);
CREATE INDEX creator_analytics_refresh_expiry ON creator_analytics_refresh(refreshed_at);
