# Postgres restore drill

Run this against Development at least quarterly and before relying on a new
backup policy. Successful WAL archive logs prove backup activity, not that a
usable database can be restored within the expected recovery window.

## Safety boundary

Use Railway's backup or point-in-time recovery controls to restore the selected
Development backup into a separate disposable Postgres service. Its database
name must end in `_restore_drill`. Never use Development or Production as the
restore target. Record the selected recovery point and start time before the
restore, then record the time the restored service becomes queryable.

The verification script does not create or overwrite a database. It compares
Postgres system identifiers plus database names, so equivalent connection URLs
cannot disguise the source as the target. It then checks the already-restored
database. Access to `pg_control_system()` is required so this check fails closed.

## Run

```bash
SOURCE_DATABASE_URL='<private or temporary source URL>' \
RESTORE_DATABASE_URL='<disposable target URL>' \
CONFIRM_RESTORE_DATABASE='social_wire_dev_restore_drill' \
bash scripts/verify-postgres-restore.sh
```

Run only after the provider restore finishes, from a trusted operator
environment with `psql`. Do not
paste URLs into tickets, logs, or chat. Record only the date, source backup
timestamp, duration, schema migration count, outcome, and follow-up issue.

The drill passes only when the target is a distinct database, its migration
history is non-empty and no newer than the source, and the migration, content,
durable-ingestion, and Operations heartbeat tables are present. Delete the
disposable restore service through Railway only after recording the result.
