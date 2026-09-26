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

## Development manifest intake handoff

The September 9 audit found two potential AppView intake owners: the legacy Jetstream V2 Ingest service and the consolidated Ingress Controller. Both used `jetstream-v2-us-west-v2`; Charybdis and Projection Pool consumed that generation. Inspect current leases again before changing anything. Stopping only the legacy ingester is insufficient when the Controller's AppView lane is enabled.

The proposed filter is the existing six collections plus `app.thesocialwire.readState`: `site.standard.document`, `site.standard.entry`, `com.standard.document`, `com.standard.entry`, `app.skyreader.feed.subscription`, `site.standard.graph.subscription`, `app.thesocialwire.readState`. The two `com.standard` entries preserve the existing transport filter; they are not new registered Lexicons. Do not add `readStateChunk`. The current filter fingerprint is `f7bfe3885b8032823ed7ce110563f7dcce83fa666355b8d04f23513631e4ba0f`; the proposed fingerprint is `e16fe433d022eecb3c4e03a0ed431ce0c78188bfebbd3884f4420983c0c4e821`. Verify these through the current configuration parser rather than copying a stale audit into a live checkpoint.

1. Deploy the compatible services with all read-state authority and eviction flags off. Stop the legacy AppView ingester and disable only the Controller's AppView lane, preserving its independent Wire lanes.
2. Verify all old AppView intake leases are released or expired. Read the old generation's exact `last_staged_seq` as seam `S` only after intake stops. The historical configured bootstrap is not this seam.
3. Drain and reconcile old-generation work through `S` with both existing projection consumers. Resolve pending reconciliation and unresolved failures explicitly; do not omit them from acceptance or erase them to permit the switch.
4. Select a new descriptive generation identity for the new filter. Update both projection consumers, or intentionally retire a legacy consumer. Configure the Controller using `JETSTREAM_APPVIEW_COLLECTIONS`, `JETSTREAM_APPVIEW_SOURCE_GENERATION`, and `JETSTREAM_APPVIEW_BOOTSTRAP_AFTER_SEQ=S-1` for inclusive overlap. The Controller does not use the legacy `JETSTREAM_COLLECTIONS` override. Keep the legacy ingester stopped, or update its matching identity before it can restart.
5. Enable the Controller AppView lane. Verify a real, non-skipped deployment, one fenced lease owner, matching host/cursor/filter fingerprint, and checkpoint progress through `S`. Reconcile the newly included PDS singleton collection for enrolled viewers so pre-seam manifests are not lost. Verify readiness and two-client immediate/eventual projection behavior before authority activation.

Changing the collection filter under an existing generation is rejected by immutable identity validation. The three public read-state Lexicons were published and their complete records/CIDs verified on September 9; publication does not itself activate ingestion or clients.

### Development execution, September 9, 2026

Compatible commit `4b8eb88ddf32c0417d4796187c7fa49fb34de199` passed required CI and all twelve triggered Development deployments. Both intake owners stopped; lease 503 released at 02:26:21 UTC. The stopped seam was `25681193101`, with staged and applied positions equal. All 48 historical failed events had an exact completed reconciliation request; no unmatched failures or actionable old queue remained. These records were preserved.

The Controller and legacy standby now use `jetstream-v2-us-west-read-state-v1`, the seven-collection filter above, and bootstrap `25681193100` for inclusive overlap. Charybdis, Projection Pool, and Coordinator use the matching generation. Replica counts and independent Wire lanes were preserved. All five resulting deployments succeeded. At 02:29:10 UTC, the new staged and applied positions were both `25681249357`, replay was live, one fenced lease owner held token 504, and no actionable queue remained. The previous checkpoint stayed at the stopped seam.

The authority table was empty before activation, so no already-authoritative pre-seam manifests required projection reconciliation. Initial client migration still verifies the complete current PDS and legacy baseline before authority changes. Authenticated migration, offline/multi-device behavior, and eviction recovery remain separate acceptance gates; Production intake and client authority have not been switched.
