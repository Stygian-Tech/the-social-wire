# TSW-92 Background Consolidation Validation

Implementation evidence recorded September 26, 2026 UTC. TSW-94 owns the linked Operations retention work. Production promotion remains gated; local correctness and synthetic query measurements do not establish live memory savings or end-to-end acceptance.

## Local Evidence

- The Wire Swift suite passed **391 tests in 51 suites** against an isolated, fully migrated PostgreSQL 17 database. Coverage includes every rollup field, inclusive hourly/daily/weekly boundaries, feedback expiry, concurrent dirty revisions, missing derived state, simulated postmaster identity changes, partition detach/reattach, publication rollback, and component connection names.
- The final combined-source run passed **391/391** against fresh `tsw92_wire_clean_final` (`/tmp/tsw92-wire-clean-final.log`). An intervening reused-database run exposed retained metadata fixtures saturating the unchanged 250-row claim test; all 12 lease cases passed alone and the fresh full run passed. Cleanup/isolation follow-up is tracked separately as TSW-130; no production claim limit was widened.
- New batch coverage uses **1,003 keys**, including one **10,001-signal article**, verifies sorted batches of at most 1,000 keys, and compares complete rollup values with the unchanged full-query oracle. Concurrent cross-key movement verifies one repeatable-read snapshot; injected serialization failures verify whole-transaction rollback/retry, the three-attempt limit, and refusal to retry cancellation or uncertain commit/rollback outcomes.
- The existing benchmark CLI safety suite passed **six tests**. One initial unrelated enrichment-count assertion passed both its isolated rerun and the subsequent complete Wire suite; no unrelated production code was changed.
- Pre-snapshot topology tests passed: a writer committing after the utility lock remains visible, normal ingestion proceeds, `ATTACH` and `DETACH CONCURRENTLY` are excluded, a busy parent fails promptly, and cancellation releases the lock. The migration runner passed fresh and repeat runs against `tsw92_fresh_final` and upgrade against `tsw92_wire`.
- Other local checks passed: **303 ThinAppViewCore tests**, **13 Indexing tests**, **43 Operations tests**, **165 OperationsCore tests**, **29 PostgreSQL retention/lease integration tests plus 23 final authority/evidence tests**, and **134 specification tests with 32 PostgreSQL-gated skips**. The full Go race suite ran against disposable PostgreSQL; Go vet/build passed. Operations Web passed **264 tests**, typecheck, lint and production build. Repository build/lint/type checks passed. The broader reader web suite has **794 passing tests and two existing checkout-path failures**, tracked separately in TSW-129; the earlier OPML contention timeout passed its rerun.
- The retirement audit corrected legacy-only Operations heartbeat selection. Projection supplies ingestion evidence; recovery and complete consolidated coverage require a lease-validated active Coordinator. Fenced heartbeat publication and read-time owner/token checks reject released or replaced owners. Current and historical dashboard coverage recognizes the replacement roles without treating standby or stale evidence as healthy.
- Live read-only comparison confirmed Charybdis and Coordinator match on RSS, retention and recovery settings in Development and Production (shared defaults, proactive backfill disabled, and Production restore timeout 120 seconds). Production Projection's existing 3,000-record enrollment cap remains separate from Coordinator/Charybdis's default 2,000; no workload cap was changed.
- Synthetic compact-envelope fixtures decreased from **346 to 318 bytes for a like**, **331 to 303 bytes for a follow**, and **326 to 193 bytes for a delete**. These are individual fixture sizes, not measured production traffic savings.
- Fixed per-lane minute samples expose original/compact input bytes, accepted insertion payload bytes, filtered passive events, subject-lookup bytes, actual inserted rows and pool waits/utilization. Successful-commit counters exclude internal serialization retries; accepted submissions include external replay duplicates while actual inserted rows do not. They add no database reads and contain no event identifiers.
- Railway reconciliation dry runs reported **18 Development changes**, **12 Production changes**, and **zero destroys**. They did not apply infrastructure changes. Read-only usage baselines are retained in `/tmp/tsw92-usage-baseline-24h-20260926.json` and `/tmp/tsw92-usage-baseline-7d-20260926.json`; they establish comparison windows rather than post-change savings.

## Synthetic Rollup Measurements

The existing `scripts/benchmarks/wire-rollup-benchmark.py` harness ran against a dedicated local PostgreSQL **18.6** container, with **600,000 signals**, **10,000 article keys**, **20,000 feedback rows**, `shared_buffers=128MB`, and `work_mem=4MB`. The selective query alone disables JIT within its transaction; the oracle retains its original settings.

Each query scenario had one measurement after restarting PostgreSQL buffers and five warm measurements. Host filesystem caches were not cleared. Other local builds were active, so elapsed times are contextual; buffer work is the sparse-read gate.

| Aggregate | Warm shared-buffer accesses | Warm median execution |
| --- | ---: | ---: |
| Full oracle | 763,926 | 1,007.474 ms |
| Selective, 100 keys (1%) | 8,556 | 24.110 ms |
| Selective, all 10,000 keys | 604,797 | 962.833 ms |

The 1% case reduced shared-buffer accesses by **98.88%**, passing the **80% sparse-read reduction** gate. These are query-work measurements, not percentages of RAM saved. The harness extracts the actual aggregate SQL, but does **not** benchmark the complete bounded-batch refresh, repeatable-read retries, atomic publication, ranking, or authenticated reader requests.

Ingestion used eight clients and 8,000 synthetic transactions per sample: three matched tracking-off/on pairs per key distribution, then one matched pair per distribution with a concurrent 10,000-key aggregate. There were 128,000 measured transactions in total. The isolated rows below show medians across the three samples; combined rows contain one pair and are not production tail-latency estimates.

| Workload | Ingest p95, off → on | Container CPU, off → on |
| --- | ---: | ---: |
| Spread keys, ingestion only | 0.118 → 0.129 ms | 561.271 → 675.844 ms |
| One hot key, ingestion only | 0.116 → 0.130 ms | 553.573 → 647.647 ms |
| Spread keys plus aggregate | 0.120 → 0.134 ms | 1,572.438 → 1,494.836 ms |
| One hot key plus aggregate | 0.119 → 0.135 ms | 1,440.571 → 1,495.967 ms |

The hot and combined samples show **more than 10% ingestion p95 growth**. Their absolute latency is small, but the result prevents claiming the latency gate has passed. Representative replay must measure actual shard distribution, source bursts, retries, pool waits, query pressure, and complete maintenance cycles before enabling the hosted selective reader.

Machine-local evidence is retained in `/tmp/tsw92-rollup-bounded-results`, `/tmp/tsw92-rollup-bounded-final-source`, and `/tmp/tsw92-wire-tests-final.log`. The second query directory verifies extraction from the final formatted source after the ingest experiment; its extra synthetic ingestion key makes it a smoke check, not the original matched fixture.

## Snapshot, Recovery, and Locking

- Batches share one `asOf`, repeatable-read source snapshot, and publication transaction. Ranking follows completed refresh. Only SQLSTATE `40001` with confirmed rollback retries, at most three attempts with 50/100 ms waits; ambiguous commit failures and cancellation propagate.
- The refresh acquires `SHARE UPDATE EXCLUSIVE` on **only the signal parent** before its first snapshot-bearing statement. This permits ordinary signal writes and prevents attachment/detachment from changing the source inventory between batches. `NOWAIT` preserves existing timeout budgets: active partition maintenance causes a failed refresh and a later scheduler retry.
- The additive migration gives tracking enable/disable the same parent-lock-before-advisory order. Apply that migration before deploying the new reader. The lock also excludes competing parent `ANALYZE`/`VACUUM`; measure maintenance overlap during replay and soak.
- Existing coverage invalidation remains authoritative: missing scheduling state, postmaster identity changes, relation topology changes, backward `asOf`, and tracking cutover require a full rebuild. Existing dirty revisions and all source facts remain retained until acknowledged or expired by existing policies. Lost client responses never justify cursor resets or deleting pending work.
- Both hosted selective flags remain off until their gates pass. The full oracle remains available for rollback. No memory limit or retention reduction is justified by these results.

## Rollout Acceptance Checklist

No deployment or soak has begun. The stale 1Password signing configuration was replaced with native macOS SSH signing using the same existing key; signed-commit verification passed. The source is ready for feature commits and required CI. Local checks are not an exact-commit CI result.

- [x] Wire local unit/integration suite and synthetic sparse-read comparison pass.
- [x] Pre-snapshot topology lock, attach/concurrent-detach exclusion, normal ingestion, and cancellation checks pass.
- [x] Additive migration fresh/upgrade/repeat checks pass.
- [ ] All affected Go/Swift suites, relevant application build/lint/type checks, migration drift checks, and the aggregate **CI — required** gate pass on the exact release commit.
- [ ] Development receives separate stages: connection ownership, compact admission, selective rollups, and telemetry catch-up. Verify rollback of each stage without resetting cursors.
- [ ] Representative replay establishes exact envelope/deletion/account-ordering parity, full-versus-selective ranking values, saturated-pool lease survival, backlog progress, and retry/DDL-maintenance behavior.
- [ ] Matched measurements show lower connection/payload/aggregate work, no growing actionable backlog or new lease failures, and no greater than **10% p95 latency regression**. Address the synthetic contention warning before asserting this gate.
- [ ] Verify live authenticated bootstrap, unread state, Your Circle participants, and newly published Wire generations. Record source freshness independently of public HTTP readiness.
- [ ] Complete a **24-hour Development soak** and matched database/Redis/worker cost, cache, relation-growth, and reusable-space comparisons. Continue the **seven-day** comparison after promotion; telemetry deletion need not immediately shrink relation files.
- [ ] Reconcile every live lane generation, collection filter, cursor domain, replay budget, and recovery scope before service handoff. Retain Production Ingress ×2, Projection ×4, Coordinator ×2 and separate public/database services.
- [ ] Retire each legacy intake/drain incrementally only after fenced takeover and replacement throughput are proven; retire Charybdis only after projection/RSS/backfill/retention/recovery coverage. Keep stopped deployments available throughout soak; do not delete services.
- [ ] Promote Production only after the preceding gates pass. On regression restore the affected stage/deployment, retain pending work and cursors, and record the outcome in TSW-92/TSW-94.
