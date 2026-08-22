#!/usr/bin/env bash
set -euo pipefail

# Stream the presentation/ranking inputs for The Wire between two Postgres
# databases without copying inbox envelopes, rank generations, or viewer state.
# Both URLs must be supplied by the operator; this script never discovers or
# persists credentials.

SOURCE_DATABASE_URL="${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
DESTINATION_DATABASE_URL="${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"
PSQL_BIN="${PSQL_BIN:-psql}"

command -v "$PSQL_BIN" >/dev/null 2>&1 || {
  echo "error: psql is required (set PSQL_BIN when it is not on PATH)" >&2
  exit 1
}

source_major="$($PSQL_BIN "$SOURCE_DATABASE_URL" -X -Atqc "SHOW server_version_num" | cut -c1-2)"
destination_major="$($PSQL_BIN "$DESTINATION_DATABASE_URL" -X -Atqc "SHOW server_version_num" | cut -c1-2)"
if [[ -z "$source_major" || "$source_major" != "$destination_major" ]]; then
  echo "error: source and destination Postgres major versions must match" >&2
  exit 1
fi

required_migration="20260821190000"
for database_url in "$SOURCE_DATABASE_URL" "$DESTINATION_DATABASE_URL"; do
  applied="$($PSQL_BIN "$database_url" -X -Atqc \
    "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = '$required_migration')")"
  if [[ "$applied" != "t" ]]; then
    echo "error: required Wire serving migration is missing" >&2
    exit 1
  fi
done

stage_sql=$(mktemp)
trap 'rm -f "$stage_sql"' EXIT

cat >"$stage_sql" <<'SQL'
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('the-wire-corpus-transfer-v1', 0));
DROP SCHEMA IF EXISTS wire_corpus_transfer CASCADE;
CREATE SCHEMA wire_corpus_transfer;

CREATE UNLOGGED TABLE wire_corpus_transfer.items AS
  SELECT * FROM public.wire_items WITH NO DATA;
CREATE UNLOGGED TABLE wire_corpus_transfer.aliases AS
  SELECT * FROM public.wire_item_aliases WITH NO DATA;
CREATE UNLOGGED TABLE wire_corpus_transfer.publications AS
  SELECT * FROM public.wire_publications WITH NO DATA;
CREATE UNLOGGED TABLE wire_corpus_transfer.actors AS
  SELECT * FROM public.wire_active_actors WITH NO DATA;
CREATE UNLOGGED TABLE wire_corpus_transfer.follow_edges AS
  SELECT * FROM public.wire_follow_edges WITH NO DATA;
CREATE UNLOGGED TABLE wire_corpus_transfer.signals AS
  SELECT event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash,
         source_uri, occurred_at, ingested_at, expires_at, transport_event_key
  FROM public.wire_signal_events WITH NO DATA;
COMMIT;
SQL

$PSQL_BIN "$DESTINATION_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$stage_sql"

stream_copy() {
  local source_query="$1"
  local destination_table="$2"
  local columns="$3"
  "$PSQL_BIN" "$SOURCE_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -c "COPY ($source_query) TO STDOUT WITH (FORMAT binary)" |
    "$PSQL_BIN" "$DESTINATION_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
      -c "COPY $destination_table ($columns) FROM STDIN WITH (FORMAT binary)"
}

stream_copy \
  "SELECT * FROM public.wire_items WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.items" \
  "canonical_key, canonical_url, representative_uri, publication_id, author_key, source_domain, source_name, author_name, title, summary, thumbnail_url, language_code, topic_keys, presentation_snapshot, provenance, published_at, first_seen_at, last_seen_at, last_signal_at, source_confidence, eligible, expires_at, updated_at"

stream_copy \
  "SELECT * FROM public.wire_item_aliases WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.aliases" \
  "alias_key, canonical_key, alias_type, created_at, expires_at"

stream_copy \
  "SELECT * FROM public.wire_publications WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.publications" \
  "publication_uri, repo_did, site_url, name, metadata, first_seen_at, last_seen_at, expires_at, updated_at"

stream_copy \
  "SELECT * FROM public.wire_active_actors WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.actors" \
  "actor_key_hash, first_active_at, last_active_at, public_signal_count, expires_at"

stream_copy \
  "SELECT * FROM public.wire_follow_edges WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.follow_edges" \
  "source_uri, follower_key_hash, followee_key_hash, observed_at, expires_at"

stream_copy \
  "SELECT event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash, source_uri, occurred_at, ingested_at, expires_at, transport_event_key FROM public.wire_signal_events WHERE expires_at > clock_timestamp()" \
  "wire_corpus_transfer.signals" \
  "event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash, source_uri, occurred_at, ingested_at, expires_at, transport_event_key"

merge_sql=$(mktemp)
trap 'rm -f "$stage_sql" "$merge_sql"' EXIT
cat >"$merge_sql" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '15min';
SELECT pg_advisory_xact_lock(hashtextextended('the-wire-corpus-transfer-v1', 0));

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM wire_corpus_transfer.items incoming
    JOIN public.wire_items current USING (canonical_url)
    WHERE incoming.canonical_key <> current.canonical_key
  ) THEN
    RAISE EXCEPTION 'canonical URL maps to conflicting Wire item keys';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM wire_corpus_transfer.aliases incoming
    JOIN public.wire_item_aliases current USING (alias_key)
    WHERE incoming.canonical_key <> current.canonical_key
  ) THEN
    RAISE EXCEPTION 'Wire alias maps to conflicting canonical item keys';
  END IF;
END
$$;

INSERT INTO public.wire_items
SELECT * FROM wire_corpus_transfer.items
ON CONFLICT (canonical_key) DO UPDATE SET
  canonical_url = EXCLUDED.canonical_url,
  representative_uri = COALESCE(public.wire_items.representative_uri, EXCLUDED.representative_uri),
  publication_id = COALESCE(public.wire_items.publication_id, EXCLUDED.publication_id),
  author_key = COALESCE(public.wire_items.author_key, EXCLUDED.author_key),
  source_domain = CASE WHEN EXCLUDED.updated_at > public.wire_items.updated_at THEN EXCLUDED.source_domain ELSE public.wire_items.source_domain END,
  source_name = CASE WHEN EXCLUDED.updated_at > public.wire_items.updated_at THEN EXCLUDED.source_name ELSE public.wire_items.source_name END,
  author_name = COALESCE(public.wire_items.author_name, EXCLUDED.author_name),
  title = CASE WHEN length(EXCLUDED.title) > length(public.wire_items.title) THEN EXCLUDED.title ELSE public.wire_items.title END,
  summary = COALESCE(public.wire_items.summary, EXCLUDED.summary),
  thumbnail_url = COALESCE(public.wire_items.thumbnail_url, EXCLUDED.thumbnail_url),
  language_code = CASE WHEN public.wire_items.language_code = 'und' THEN EXCLUDED.language_code ELSE public.wire_items.language_code END,
  topic_keys = (
    SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
    FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(public.wire_items.topic_keys || EXCLUDED.topic_keys)) values
  ),
  presentation_snapshot = CASE WHEN EXCLUDED.updated_at > public.wire_items.updated_at THEN EXCLUDED.presentation_snapshot ELSE public.wire_items.presentation_snapshot END,
  provenance = (
    SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
    FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(public.wire_items.provenance || EXCLUDED.provenance)) values
  ),
  published_at = COALESCE(public.wire_items.published_at, EXCLUDED.published_at),
  first_seen_at = LEAST(public.wire_items.first_seen_at, EXCLUDED.first_seen_at),
  last_seen_at = GREATEST(public.wire_items.last_seen_at, EXCLUDED.last_seen_at),
  last_signal_at = GREATEST(public.wire_items.last_signal_at, EXCLUDED.last_signal_at),
  source_confidence = GREATEST(public.wire_items.source_confidence, EXCLUDED.source_confidence),
  eligible = public.wire_items.eligible AND EXCLUDED.eligible,
  expires_at = GREATEST(public.wire_items.expires_at, EXCLUDED.expires_at),
  updated_at = GREATEST(public.wire_items.updated_at, EXCLUDED.updated_at);

INSERT INTO public.wire_item_aliases
SELECT * FROM wire_corpus_transfer.aliases
ON CONFLICT (alias_key) DO UPDATE SET
  alias_type = EXCLUDED.alias_type,
  created_at = LEAST(public.wire_item_aliases.created_at, EXCLUDED.created_at),
  expires_at = GREATEST(public.wire_item_aliases.expires_at, EXCLUDED.expires_at);

INSERT INTO public.wire_publications
SELECT * FROM wire_corpus_transfer.publications
ON CONFLICT (publication_uri) DO UPDATE SET
  repo_did = CASE WHEN EXCLUDED.last_seen_at > public.wire_publications.last_seen_at THEN EXCLUDED.repo_did ELSE public.wire_publications.repo_did END,
  site_url = CASE WHEN EXCLUDED.last_seen_at > public.wire_publications.last_seen_at THEN EXCLUDED.site_url ELSE public.wire_publications.site_url END,
  name = CASE WHEN EXCLUDED.last_seen_at > public.wire_publications.last_seen_at THEN EXCLUDED.name ELSE public.wire_publications.name END,
  metadata = CASE WHEN EXCLUDED.last_seen_at > public.wire_publications.last_seen_at THEN EXCLUDED.metadata ELSE public.wire_publications.metadata END,
  first_seen_at = LEAST(public.wire_publications.first_seen_at, EXCLUDED.first_seen_at),
  last_seen_at = GREATEST(public.wire_publications.last_seen_at, EXCLUDED.last_seen_at),
  expires_at = GREATEST(public.wire_publications.expires_at, EXCLUDED.expires_at),
  updated_at = GREATEST(public.wire_publications.updated_at, EXCLUDED.updated_at);

INSERT INTO public.wire_active_actors
SELECT * FROM wire_corpus_transfer.actors
ON CONFLICT (actor_key_hash) DO UPDATE SET
  first_active_at = LEAST(public.wire_active_actors.first_active_at, EXCLUDED.first_active_at),
  last_active_at = GREATEST(public.wire_active_actors.last_active_at, EXCLUDED.last_active_at),
  public_signal_count = GREATEST(public.wire_active_actors.public_signal_count, EXCLUDED.public_signal_count),
  expires_at = GREATEST(public.wire_active_actors.expires_at, EXCLUDED.expires_at);

DELETE FROM public.wire_follow_edges current
USING wire_corpus_transfer.follow_edges incoming
WHERE incoming.observed_at > current.observed_at
  AND (
    incoming.source_uri = current.source_uri
    OR (
      incoming.follower_key_hash = current.follower_key_hash
      AND incoming.followee_key_hash = current.followee_key_hash
    )
  );

INSERT INTO public.wire_follow_edges
SELECT incoming.*
FROM wire_corpus_transfer.follow_edges incoming
WHERE NOT EXISTS (
  SELECT 1 FROM public.wire_follow_edges current
  WHERE current.observed_at >= incoming.observed_at
    AND (
      current.source_uri = incoming.source_uri
      OR (
        current.follower_key_hash = incoming.follower_key_hash
        AND current.followee_key_hash = incoming.followee_key_hash
      )
    )
)
ON CONFLICT DO NOTHING;

SELECT ensure_wire_signal_event_partition(day::date)
FROM (
  SELECT DISTINCT date_trunc('day', occurred_at) AS day
  FROM wire_corpus_transfer.signals
) days;

DELETE FROM public.wire_signal_events current
USING wire_corpus_transfer.signals incoming
WHERE incoming.source_uri = current.source_uri
  AND incoming.occurred_at > current.occurred_at;

INSERT INTO public.wire_signal_events
  (event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash,
   source_uri, occurred_at, ingested_at, expires_at, transport_event_key)
SELECT incoming.*
FROM wire_corpus_transfer.signals incoming
WHERE NOT EXISTS (
  SELECT 1 FROM public.wire_signal_events current
  WHERE current.source_uri = incoming.source_uri
    AND current.occurred_at >= incoming.occurred_at
)
ON CONFLICT DO NOTHING;

DROP SCHEMA wire_corpus_transfer CASCADE;
COMMIT;

ANALYZE public.wire_items;
ANALYZE public.wire_item_aliases;
ANALYZE public.wire_publications;
ANALYZE public.wire_active_actors;
ANALYZE public.wire_follow_edges;
ANALYZE public.wire_signal_events;
SQL

$PSQL_BIN "$DESTINATION_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$merge_sql"

echo "The Wire canonical corpus inputs transferred successfully."
