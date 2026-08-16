# Finding the Last Safe Checkpoint

No single transport cursor proves repository or projection completeness. The current safe recovery position combines the fenced Jetstream V2 inbox cursor, last durably indexed mutation, projection-repair watermark, and validation watermark. Historical Tap acknowledgement and per-repository revision rows remain rollback evidence only. `appview_ingestion_stream_state.last_committed_cursor` remains transport evidence rather than proof of repository completeness.

1. Record the source, repository DID/revision when applicable, delivery or transport cursor, event timestamp, observed timestamp, and evidence accuracy.
2. Compare it with the latest content index write, projection-repair watermark, validation watermark, and recovery failures.
3. For a Jetstream diagnostic replay, start five seconds before the committed transport cursor and keep results in **Verification Required**.
4. For recovery, replay the durable V2 inbox or run DID-scoped PDS reconciliation, then wait for durable indexing, projection repair, and exact-scope validation.

The legacy per-repository checkpoint table is rollback evidence only and must not be promoted to verified Tap state.
