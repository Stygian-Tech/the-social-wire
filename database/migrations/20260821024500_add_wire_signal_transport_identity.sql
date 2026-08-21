-- A source generation identifies a replay/filter configuration, not a public event.
-- Preserve the transport identity separately so overlapping successor generations
-- cannot count the same Jetstream event twice.
ALTER TABLE wire_signal_events
  ADD COLUMN IF NOT EXISTS transport_event_key TEXT;

UPDATE wire_signal_events signal
SET transport_event_key = concat_ws(
  ':', 'transport', inbox.environment, inbox.source_host, inbox.cursor_kind, inbox.seq::text
)
FROM wire_ingestion_inbox inbox
WHERE signal.transport_event_key IS NULL
  AND signal.event_key = concat_ws(
    ':', inbox.environment, inbox.source_generation, inbox.seq::text
  );

-- A public source record has one current signal meaning. Collapse historical update
-- rows even when their short-lived inbox envelopes were already pruned and therefore
-- could not be backfilled with a transport key.
DELETE FROM wire_signal_events older
USING wire_signal_events newer
WHERE older.source_uri = newer.source_uri
  AND (
    older.occurred_at < newer.occurred_at
    OR (older.occurred_at = newer.occurred_at AND older.id < newer.id)
  );

DELETE FROM wire_signal_events duplicate
USING wire_signal_events keeper
WHERE duplicate.transport_event_key IS NOT NULL
  AND duplicate.transport_event_key = keeper.transport_event_key
  AND duplicate.occurred_at = keeper.occurred_at
  AND duplicate.id > keeper.id;

CREATE UNIQUE INDEX IF NOT EXISTS wire_signal_events_transport_identity_idx
  ON wire_signal_events (occurred_at, transport_event_key)
  WHERE transport_event_key IS NOT NULL;

COMMENT ON COLUMN wire_signal_events.transport_event_key IS
  'Generation-independent source identity: environment, source host, cursor kind, and sequence.';
