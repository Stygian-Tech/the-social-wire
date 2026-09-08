# PDS Read-State Projection Recovery

PDS authority begins only after a complete CID-verified generation passes the legacy-revision and baseline-parity gate. The AppView retains legacy source rows and the verified authority record. PostgreSQL holds one active derived projection; ordinary linked appends send only new actions, and rebuilds compare a complete temporary projection to suppress unchanged writes.

Idle eviction is **off by default**. The Development trial settings are:

```
THIN_APPVIEW_PDS_READ_STATE_EVICTION_ENABLED=true
THIN_APPVIEW_PDS_READ_STATE_IDLE_DAYS=7
```

Apply these to the cleanup worker only after the new Database Migrator job, compatible AppView/worker builds, PDS client migration tests, and authenticated recovery QA pass. The minimum supported idle interval is seven days. An authenticated read touches last access at most once per hour. Background manifest events leave evicted viewers cold; the next authenticated read fetches the current authoritative PDS generation.

Each cleanup transaction locks one eligible migrated viewer, marks the projection unavailable, and removes at most 1,000 exact rows and 1,000 boundary rows. Further batches drain remaining derived rows. Pending/retry/leased/dead-letter inbox work, incomplete repository reconciliation, and live rebuild leases exclude a viewer. Legacy migration data, manifests, source corpus, read controls, and durable authority are retained.

An evicted projection cannot fall back to legacy read marks or appear as all unread. SQL state evaluation fails closed. AppView checks readiness before cached or streamed reader responses. While rebuilding, readers receive HTTP 503 with `ReadStateNotReady` and `retryable: true`; status remains readable with `projectionReady: false` and also schedules recovery. Confirmation waits behind the same readiness gate.

Recovery uses the existing durable Operations leases: one per viewer and two global rebuild slots per environment. Each rebuild has a 90-second deadline under a 120-second lease. Failures leave the projection unavailable, release leases, and delay retries for 30 seconds. A verified complete generation becomes ready in the same transaction that publishes its rows. Confirmation invalidates sidebar, unread-count, and first-page caches before returning success; a failed invalidation remains retryable. The public PDS HTTP pool disallows redirects and sends no viewer credentials; immutable verified chunk caching is bounded to 8 MiB.

Before enabling Production eviction, verify a migrated viewer's exact and boundary actions, evict its derived rows in Development through the janitor, and confirm that both web and Apple clients show retryable recovery rather than zero unread counts. Include PDS outage, simultaneous readers across two AppView instances, timeout, Redis loss, and restoration of the same manifest CID. Record elapsed recovery time and ingestion queue age. Unit/integration tests are implementation evidence, not a substitute for this authenticated trial.

To stop eviction, set `THIN_APPVIEW_PDS_READ_STATE_EVICTION_ENABLED=false`. Keep readiness-aware AppView code deployed until every evicted viewer is recovered; disabling cleanup does not change PDS authority or recreate rows. Never remove the readiness guard or manually delete active projection rows.

Manifest intake is a separate gate. The Go AppView default collection filter is intentionally unchanged. Add `app.thesocialwire.readState` only through an explicit collection configuration and deliberate generation/cursor handoff. Do not add `app.thesocialwire.readStateChunk`: unreferenced chunks must not enter the inbox. Preserve and drain old inbox work and verify the new fingerprint/position before enabling cross-client authority.


## Compact protocol generations

Initial authority migration exports and confirms the complete v1 baseline before upgrading to v2. The v2 singleton has a maintenance revision independent of the last user-action sequence and separate roots for executable state, device receipts, and finite legacy receipts. AppView rejects older revisions, sequence rewinds, and protocol downgrades. A revision-only maintenance update with identical verified roots does not rewrite projection rows. Explicit same-CID recovery still reconstructs missing derived rows.

Both clients persist a device counter and a prefix hash before publishing. Unknown-success retries must prove acknowledgement against that prefix; an old counter alone cannot acknowledge unrelated intent. Semantic compaction preserves exact overrides and only removes boundaries proven dominated within the same frozen scope. It preserves calendar metadata and retry receipts. Active writers compact after 64 state chunks; control-history chunks do not trigger repeated full-state rewrites. Irreducible unique state remains bounded and fails closed at the generation size limit rather than silently dropping history.

The server caches raw CID-verified v1/v2 records under one 8 MiB, 512-entry, one-hour budget, keyed by complete viewer URI and CID. Generation loading retains the 64 KiB per-record and aggregate limits across all three roots. Garbage collection is a separate gate: signed repository membership proof and an atomic repository CAS must bind the manifest revision change and every deletion to the same commit. A grace period alone is insufficient. Keep deletion disabled until the proof transport and concurrent-writer tests pass.
