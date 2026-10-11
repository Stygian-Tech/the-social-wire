-- Only HMAC pseudonyms and known tab labels; no DIDs, handles, URLs, or content.
CREATE TABLE IF NOT EXISTS operations_tab_activity (
 environment text NOT NULL CHECK(environment IN ('local','dev','test','production','prod')),
 activity_day date NOT NULL,
 viewer_key text NOT NULL CHECK(viewer_key ~ '^[0-9a-f]{64}$'),
 tab text NOT NULL CHECK(tab IN ('home','explore','notifications','messages','bookmarks','lists','feeds','saved','archive','wire','circle','finance','sports','subscribed','following','podcasts','articles','live-post','livestream','brand-accounts','analytics','profile','content-calendar')),
 opens integer NOT NULL CHECK(opens BETWEEN 0 AND 10000),
 dwell_ms double precision NOT NULL CHECK(dwell_ms BETWEEN 0 AND 86400000),
 PRIMARY KEY(environment,activity_day,viewer_key,tab)
);
CREATE INDEX IF NOT EXISTS operations_tab_activity_expiry ON operations_tab_activity(activity_day);
