-- Circle stores the complete private graph snapshot envelope, not only the member array.
-- The original array constraint rejected every cache write and forced upstream rebuilds.
ALTER TABLE appview_circle_graph_snapshots
  DROP CONSTRAINT IF EXISTS appview_circle_graph_actor_facts_array;

ALTER TABLE appview_circle_graph_snapshots
  DROP CONSTRAINT IF EXISTS appview_circle_graph_actor_facts_object;

ALTER TABLE appview_circle_graph_snapshots
  ADD CONSTRAINT appview_circle_graph_actor_facts_object
    CHECK (jsonb_typeof(actor_facts) = 'object');
