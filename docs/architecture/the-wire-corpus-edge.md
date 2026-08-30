# The Wire Corpus Edge

Production is the only authority for The Wire corpus, replay, labels, ranking generations, and retention. Development never runs an independent canonical Wire ingest or ranking worker after cutover.

```text
Production Jetstream/backfill -> Production Wire Worker -> Production Postgres
                                                               |             |
                         local corpus reads + viewer moderation |             | private read-only
                         + environment-local cursor signing     |             v
                                                               v    Production Wire Corpus Edge
                                                Production AppView            |
                                                                  signed HTTPS, no viewer auth
                                                                             v
Development Gateway -> Development AppView -> local viewer moderation/cursors
                                             |
                                             +-> Development Postgres for Subscribed/Following only
```

The edge queries only `wire_serving` views. Public Wire views apply corpus eligibility, retention, baseline-label exclusions, and generation lifecycle while omitting raw signals, actor hashes, scores, diagnostics, counts, and viewer/Operations state. The trusted `circle_signal_facts` view is the sole exception: it exposes opaque actor hashes and exact signal facts to the body-authenticated Circle candidate operation, but never raw DIDs, viewer state, or ranking scores. Public Wire responses contain presentation fields, rank ordinal, reasons, provenance, and the public source/author identifier needed for local viewer filtering; Circle responses return bounded eligible stories and matched opaque facts for Development AppView to join against its private graph snapshot.

Production AppView deliberately keeps `PostgresWireFeedStore` on its local canonical database; it does not call the public edge. Development AppView uses `RemoteWireFeedStore`. Both stores apply the same `WireFeedStore` contract, viewer moderation, and environment-local cursor signing. AppView rejects Corpus Edge configuration when `APP_ENV=prod`, preventing an accidental public-network dependency or trust loop in Production. The single edge credential is therefore scoped to Development AppView and can be rotated independently of Gateway/AppView internal trust.

AppView sends no viewer DID, access token, DPoP proof, cookie, muted word, raw graph DID, or block/mute set to Production. Circle candidate requests contain only chunked opaque actor hashes. AppView validates the edge contract version, applies viewer moderation from the viewer's own PDS, and mints cursors with environment-local secrets. A corpus outage returns The Wire or Your Circle unavailable and does not change AppView readiness or the local Subscribed/Following path.

## Rollout

1. Promote the serving-view migration through the Production Database Migrator.
2. Run Production global ingest/backfill and Worker in `shadow`; verify label freshness, retention, and generation quality.
3. Move the Production Worker to `api` so it commits the canonical active pointer while the public Production navigation may remain hidden.
4. Provision the Corpus Edge only in Production, on `main`, using private `DATABASE_URL`, the dedicated edge trust secret, and the matching Development AppView service ID.
5. Configure Development AppView with the edge HTTPS origin and dedicated client secret. Keep its own cursor secret and Development database.
6. Verify ranked/fallback moderation, retained-generation cursors, replay rejection, no CORS, and Wire-only failure isolation.
7. Stop Development Wire ingest, snapshots, and Wire Worker. Do not silently fall back to Development corpus tables.

Rollback is configuration-only: set Development `WIRE_FEED_MODE=off` or remove the edge configuration. It does not mutate or copy the Production corpus.
