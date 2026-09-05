#!/usr/bin/env bash
# Verify an explicitly named disposable database restored through the hosted backup path.
set -euo pipefail

SOURCE_DATABASE_URL="${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
RESTORE_DATABASE_URL="${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL is required}"
CONFIRM_RESTORE_DATABASE="${CONFIRM_RESTORE_DATABASE:?CONFIRM_RESTORE_DATABASE is required}"

command -v psql >/dev/null 2>&1 || {
  echo 'error: psql is required.' >&2
  exit 1
}

if [ "$SOURCE_DATABASE_URL" = "$RESTORE_DATABASE_URL" ]; then
  echo 'error: source and restore database URLs must be different.' >&2
  exit 1
fi

database_identity_sql="SELECT system_identifier::text || '/' || current_database() FROM pg_control_system()"
source_database_identity="$(psql "$SOURCE_DATABASE_URL" -X -Atqc "$database_identity_sql")"
restore_database_identity="$(psql "$RESTORE_DATABASE_URL" -X -Atqc "$database_identity_sql")"
if [ -z "$source_database_identity" ] || [ -z "$restore_database_identity" ]; then
  echo 'error: unable to resolve source and restore database identities.' >&2
  exit 1
fi
if [ "$source_database_identity" = "$restore_database_identity" ]; then
  echo 'error: source and restore connections resolve to the same database.' >&2
  exit 1
fi

restore_database_name="${restore_database_identity#*/}"
if [ "$restore_database_name" != "$CONFIRM_RESTORE_DATABASE" ]; then
  echo 'error: CONFIRM_RESTORE_DATABASE does not match the restore target.' >&2
  exit 1
fi
if [[ ! "$restore_database_name" =~ _restore_drill$ ]]; then
  echo 'error: restore target database name must end with _restore_drill.' >&2
  exit 1
fi

verified="$(psql "$RESTORE_DATABASE_URL" -X -Atqc "
  SELECT
    to_regclass('public.schema_migrations') IS NOT NULL
    AND to_regclass('public.content_items') IS NOT NULL
    AND to_regclass('public.appview_ingestion_inbox') IS NOT NULL
    AND to_regclass('public.operations_service_state') IS NOT NULL;
")"
if [ "$verified" != "t" ]; then
  echo 'error: restored database is missing one or more required tables.' >&2
  exit 1
fi

source_migration_count="$(psql "$SOURCE_DATABASE_URL" -X -Atqc 'SELECT COUNT(*) FROM public.schema_migrations')"
restore_migration_count="$(psql "$RESTORE_DATABASE_URL" -X -Atqc 'SELECT COUNT(*) FROM public.schema_migrations')"
if [ "$restore_migration_count" -le 0 ] || [ "$restore_migration_count" -gt "$source_migration_count" ]; then
  echo 'error: restored migration history is empty or newer than the source.' >&2
  exit 1
fi

echo "Restore schema checks passed ($restore_migration_count of $source_migration_count source migrations present)."
echo 'Recovery-point, durable-row integrity, restart, and rebuild checks are still required.'
