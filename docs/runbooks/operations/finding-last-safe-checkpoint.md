# Finding the Last Safe Checkpoint

No single transport cursor proves repository or projection completeness. The safe recovery position combines the Tap delivery acknowledgement, per-repository revision, last durably indexed mutation, projection-repair watermark, and validation watermark. During the Jetstream transition, `appview_ingestion_stream_state.last_committed_cursor` remains transport evidence only.

1. Record the source, repository DID/revision when applicable, delivery or transport cursor, event timestamp, observed timestamp, and evidence accuracy.
2. Compare it with the latest content index write, projection-repair watermark, validation watermark, and recovery failures.
3. For a Jetstream diagnostic replay, start five seconds before the committed transport cursor and keep results in **Verification Required**.
4. For verified recovery, request Tap resync and wait for durable indexing, projection repair, acknowledgement, and exact-scope validation.

The legacy per-repository checkpoint table is rollback evidence only and must not be promoted to verified Tap state.
