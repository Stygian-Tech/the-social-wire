# The Wire Canonical Corpus Cutover

Production owns the canonical corpus. Development consumes presentation-safe
ranked generations through the signed Wire Corpus Edge; it never connects to
Production Postgres and never receives raw signals or actor hashes.

## Historical transfer

Use `scripts/transfer-wire-corpus.sh` to seed Production from a paused source
database. The script streams only non-expired, rebuildable ranking inputs:

- items and canonical aliases;
- Standard Site publication metadata;
- HMAC actor aggregates and bounded follow edges; and
- retained public signal events.

It intentionally excludes ingestion inbox envelopes, admission counters,
checkpoints, leases, labels, communities, rollups, rank generations, feed
pointers, Redis state, and viewer data. Production rebuilds those locally.

The transfer uses an advisory lock, unlogged staging tables, conflict checks,
timestamp-aware upserts, and one short merge transaction. It is safe to retry.
Source and destination must run the same Postgres major version and have the
Wire serving migration applied.

```bash
SOURCE_DATABASE_URL='postgresql://...' \
DESTINATION_DATABASE_URL='postgresql://...' \
PSQL_BIN=/path/to/psql \
scripts/transfer-wire-corpus.sh
```

Keep credentials out of shell history in normal operation by injecting the two
URLs from the deployment platform or a short-lived local process environment.

## Activation order

1. Pause Development ingestion and ranking, retaining its database for rollback.
2. Verify the actor HMAC versions/secrets are compatible without printing them.
3. Run the canonical-input transfer and reconcile source/destination counts.
4. Run the Production Worker in `shadow` until it rebuilds moderation labels,
   communities, rollups, and a healthy generation.
5. Change the Production Worker to `api` and verify `activated=true`.
6. Deploy the Production Wire Corpus Edge with a dedicated read-only database
   role and HMAC secret.
7. Configure Development AppView with the edge origin, service identity, and
   matching HMAC secret; set AppView and Gateway to `visible`.
8. Verify catalog, first page, pagination, item detail, stale fallback, and that
   no raw scores/counts/actors appear.
9. Remove temporary database access and keep the paused Development database
   until the rollback window closes.

## Production-native replay

Do not migrate the large Development inbox. Resume historical coverage through
bounded Production snapshot generations, oldest window first. Allow each window
to drain before starting the next, then seal the delta to the live cursor and
resume the Production live generation. This preserves chronological application
and prevents an imported old generation from racing newer live records.
