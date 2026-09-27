-- Preserve the four ordered signal statements while avoiding three client round trips.
-- Callers retain transaction ownership; dirty-key triggers and revisions are unchanged.
-- The existing statement_timeout now bounds the whole call, not each command.
-- Keep public first for the partition helper's unqualified CREATE target;
-- pg_catalog remains implicitly first for builtin lookup, and pg_temp is last.
CREATE FUNCTION public.wire_insert_signal(
  p_event_key text,
  p_transport_event_key text,
  p_canonical_key text,
  p_signal_kind text,
  p_actor_key_hash text,
  p_source_uri text,
  p_source_collection text,
  p_occurred_at timestamptz,
  p_expires_at timestamptz
) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Separate commands are intentional: after a source-lock wait, READ COMMITTED
  -- must see the winner's committed rows before deleting or rejecting older work.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_source_uri, 0));
  PERFORM public.ensure_wire_signal_event_partition((p_occurred_at AT TIME ZONE 'UTC')::date);
  DELETE FROM public.wire_signal_events
    WHERE source_uri = p_source_uri AND occurred_at <= p_occurred_at;
  INSERT INTO public.wire_signal_events
    (event_key, transport_event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
     source_collection, source_action, occurred_at, expires_at)
  SELECT
    p_event_key, p_transport_event_key, p_canonical_key, p_signal_kind, p_actor_key_hash,
    p_source_uri, p_source_collection, p_signal_kind, p_occurred_at, p_expires_at
  WHERE NOT EXISTS (
    SELECT 1 FROM public.wire_signal_events
    WHERE source_uri = p_source_uri AND occurred_at > p_occurred_at
  )
  ON CONFLICT DO NOTHING;
END;
$$;
