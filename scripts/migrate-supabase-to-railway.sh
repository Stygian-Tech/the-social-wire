#!/usr/bin/env bash
# Copy Social Wire application data from Supabase Postgres into Railway Postgres.
#
# This intentionally restores data only. Railway's schema is owned by the checked-in
# Supabase migrations and must be applied before this script runs.
#
# Required:
#   SUPABASE_SOURCE_DATABASE_URL  Direct or session-pooler (port 5432) source URL
#
# Optional:
#   RAILWAY_TARGET_DATABASE_URL   Skip Railway TCP-proxy discovery and use this URL
#   RAILWAY_PROJECT_ID            Explicit Railway project ID (otherwise linked project)
#   RAILWAY_ENVIRONMENT           Defaults to production
#   RAILWAY_POSTGRES_SERVICE      Defaults to Postgres
#   MIGRATION_ARTIFACT_DIR        Defaults to .migration-artifacts/supabase-to-railway
#   MIGRATION_RESTORE_JOBS        Defaults to 2
#   MIGRATION_VERIFY_CHECKSUMS    Set to 1 for full row-content checksums
#   KEEP_RAILWAY_TCP_PROXY        Set to 1 to retain a proxy created by this script
#
# Destructive restore guard:
#   MIGRATION_WRITERS_PAUSED=YES
#   MIGRATION_CONFIRM_TARGET_RESET='The Social Wire/production/Postgres'
#
# Usage:
#   bash scripts/migrate-supabase-to-railway.sh preflight
#   bash scripts/migrate-supabase-to-railway.sh export
#   bash scripts/migrate-supabase-to-railway.sh restore
#   bash scripts/migrate-supabase-to-railway.sh verify
#   bash scripts/migrate-supabase-to-railway.sh migrate
set -euo pipefail

export LC_ALL=C
export PGTZ=UTC
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

COMMAND="${1:-preflight}"
SOURCE_DATABASE_URL="${SUPABASE_SOURCE_DATABASE_URL:-}"
TARGET_DATABASE_URL="${RAILWAY_TARGET_DATABASE_URL:-}"
RAILWAY_ENVIRONMENT="${RAILWAY_ENVIRONMENT:-production}"
RAILWAY_POSTGRES_SERVICE="${RAILWAY_POSTGRES_SERVICE:-Postgres}"
RAILWAY_PROJECT_ID="${RAILWAY_PROJECT_ID:-}"
ARTIFACT_DIR="${MIGRATION_ARTIFACT_DIR:-.migration-artifacts/supabase-to-railway}"
ARCHIVE_PATH="$ARTIFACT_DIR/public-data.dump"
TABLES_PATH="$ARTIFACT_DIR/public-tables.txt"
SOURCE_COUNTS_PATH="$ARTIFACT_DIR/source-counts.tsv"
TARGET_COUNTS_PATH="$ARTIFACT_DIR/target-counts.tsv"
SOURCE_CHECKSUMS_PATH="$ARTIFACT_DIR/source-checksums.tsv"
TARGET_CHECKSUMS_PATH="$ARTIFACT_DIR/target-checksums.tsv"
RESTORE_JOBS="${MIGRATION_RESTORE_JOBS:-2}"
CREATED_PROXY_ID=""

railway_scope=(--service "$RAILWAY_POSTGRES_SERVICE" --environment "$RAILWAY_ENVIRONMENT")
if [ -n "$RAILWAY_PROJECT_ID" ]; then
  railway_scope+=(--project "$RAILWAY_PROJECT_ID")
fi

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  echo "error: $*" >&2
  exit 1
}

notice() {
  echo "==> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_source_url() {
  [ -n "$SOURCE_DATABASE_URL" ] || fail "SUPABASE_SOURCE_DATABASE_URL is required"
  case "$SOURCE_DATABASE_URL" in
    *:6543/*) fail "use a Supabase direct or session-pooler URL on port 5432, not transaction-pooler port 6543" ;;
  esac
}

cleanup_proxy() {
  if [ -z "$CREATED_PROXY_ID" ] || [ "${KEEP_RAILWAY_TCP_PROXY:-0}" = "1" ]; then
    return
  fi

  notice "Removing temporary Railway Postgres TCP proxy"
  railway tcp-proxy delete "$CREATED_PROXY_ID" "${railway_scope[@]}" --yes --json >/dev/null \
    || echo "warning: could not remove temporary TCP proxy $CREATED_PROXY_ID" >&2
}

trap cleanup_proxy EXIT

wait_for_proxy() {
  local proxy_id="$1"
  local status_json status
  for _ in $(seq 1 30); do
    status_json="$(railway tcp-proxy status "$proxy_id" "${railway_scope[@]}" --json)"
    status="$(jq -r '.proxy.syncStatus // .syncStatus // empty' <<<"$status_json")"
    if [ "$status" = "ACTIVE" ]; then
      return
    fi
    if [ "$status" = "FAILED" ]; then
      fail "Railway TCP proxy failed to activate"
    fi
    sleep 1
  done
  fail "timed out waiting for Railway TCP proxy"
}

resolve_target_url() {
  local proxies_json proxy_id create_json variables_json
  if [ -n "$TARGET_DATABASE_URL" ]; then
    return
  fi

  require_tool railway
  require_tool jq

  proxies_json="$(railway tcp-proxy list "${railway_scope[@]}" --json)"
  proxy_id="$(jq -r '.proxies[0].id // empty' <<<"$proxies_json")"
  if [ -z "$proxy_id" ]; then
    notice "Creating temporary Railway Postgres TCP proxy"
    create_json="$(railway tcp-proxy create --port 5432 "${railway_scope[@]}" --json)"
    proxy_id="$(jq -r '.proxy.id // empty' <<<"$create_json")"
    [ -n "$proxy_id" ] || fail "Railway did not return a TCP proxy ID"
    CREATED_PROXY_ID="$proxy_id"
  fi

  wait_for_proxy "$proxy_id"
  variables_json="$(railway variable list "${railway_scope[@]}" --json)"
  TARGET_DATABASE_URL="$(jq -r '.DATABASE_PUBLIC_URL // empty' <<<"$variables_json")"
  [ -n "$TARGET_DATABASE_URL" ] || fail "Railway Postgres does not expose DATABASE_PUBLIC_URL after proxy activation"
}

psql_scalar() {
  local database_url="$1"
  local sql="$2"
  psql "$database_url" -X -v ON_ERROR_STOP=1 -Atqc "$sql"
}

server_major() {
  local database_url="$1"
  local version_num
  version_num="$(psql_scalar "$database_url" "SHOW server_version_num")"
  printf '%s\n' "$((version_num / 10000))"
}

client_major() {
  pg_dump --version | sed -E 's/.* ([0-9]+)(\..*)?$/\1/'
}

inventory_tables() {
  local database_url="$1"
  psql_scalar "$database_url" \
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"
}

migration_versions() {
  local database_url="$1"
  psql_scalar "$database_url" \
    "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version"
}

compare_schema_contract() {
  local source_tables target_tables source_migrations target_migrations
  source_tables="$(mktemp)"
  target_tables="$(mktemp)"
  source_migrations="$(mktemp)"
  target_migrations="$(mktemp)"

  inventory_tables "$SOURCE_DATABASE_URL" >"$source_tables"
  inventory_tables "$TARGET_DATABASE_URL" >"$target_tables"
  if ! diff -u "$source_tables" "$target_tables"; then
    fail "source and target public table sets differ; reconcile schema drift before copying data"
  fi

  migration_versions "$SOURCE_DATABASE_URL" >"$source_migrations"
  migration_versions "$TARGET_DATABASE_URL" >"$target_migrations"
  if ! diff -u "$source_migrations" "$target_migrations"; then
    fail "source and target migration histories differ; apply or repair migrations before copying data"
  fi
}

check_for_unsupported_source_data() {
  local custom_schemas large_objects
  custom_schemas="$(psql_scalar "$SOURCE_DATABASE_URL" \
    "SELECT DISTINCT table_schema
     FROM information_schema.tables
     WHERE table_type = 'BASE TABLE'
       AND table_schema NOT IN (
         'public', 'auth', 'storage', 'realtime', 'extensions', 'graphql', 'graphql_public',
         'pgbouncer', 'supabase_functions', 'supabase_migrations', 'vault',
         'analytics', '_analytics', '_realtime', 'cron', 'net', 'pgmq', 'pgsodium',
         'pgsodium_masks', 'pgtle', 'repack', 'tiger', 'tiger_data', 'topology',
         'timescaledb', 'timescaledb_information', 'information_schema', 'pg_catalog'
       )
       AND table_schema NOT LIKE 'pg_toast%'
       AND table_schema NOT LIKE 'pg_temp%'
     ORDER BY table_schema")"
  if [ -n "$custom_schemas" ]; then
    echo "Unsupported application schema(s) outside public:" >&2
    printf '%s\n' "$custom_schemas" >&2
    fail "extend and review the migration scope before copying data"
  fi

  large_objects="$(psql_scalar "$SOURCE_DATABASE_URL" "SELECT count(*) FROM pg_largeobject_metadata")"
  if [ "$large_objects" -ne 0 ]; then
    fail "source contains $large_objects PostgreSQL large object(s), which this public-schema data migration does not copy"
  fi
}

preflight() {
  local source_major target_major dump_major source_size source_tables target_tables
  require_source_url
  resolve_target_url

  source_major="$(server_major "$SOURCE_DATABASE_URL")"
  target_major="$(server_major "$TARGET_DATABASE_URL")"
  dump_major="$(client_major)"
  if [ "$dump_major" -lt "$source_major" ]; then
    fail "pg_dump major $dump_major is older than Supabase Postgres major $source_major"
  fi

  source_size="$(psql_scalar "$SOURCE_DATABASE_URL" "SELECT pg_size_pretty(pg_database_size(current_database()))")"
  source_tables="$(inventory_tables "$SOURCE_DATABASE_URL" | wc -l)"
  target_tables="$(inventory_tables "$TARGET_DATABASE_URL" | wc -l)"

  notice "Source Postgres major: $source_major"
  notice "Target Postgres major: $target_major"
  notice "pg_dump major: $dump_major"
  notice "Source database size: $source_size"
  notice "Public tables: source=$source_tables target=$target_tables"

  check_for_unsupported_source_data
  compare_schema_contract
  notice "Schema and migration history match"
}

validate_table_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "unsupported public table identifier: $1"
}

collect_counts() {
  local database_url="$1"
  local tables_file="$2"
  local output_file="$3"
  local temporary_output table count
  temporary_output="${output_file}.tmp"
  : >"$temporary_output"
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    validate_table_name "$table"
    count="$(psql_scalar "$database_url" "SELECT count(*) FROM public.\"$table\"")"
    printf '%s\t%s\n' "$table" "$count" >>"$temporary_output"
  done <"$tables_file"
  mv "$temporary_output" "$output_file"
}

collect_checksums() {
  local database_url="$1"
  local tables_file="$2"
  local output_file="$3"
  local temporary_output table checksum
  temporary_output="${output_file}.tmp"
  : >"$temporary_output"
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    validate_table_name "$table"
    checksum="$({
      echo "SET TIME ZONE 'UTC';"
      echo "COPY (SELECT md5(to_jsonb(t)::text) AS row_hash FROM public.\"$table\" AS t ORDER BY row_hash) TO STDOUT;"
    } | psql "$database_url" -X -v ON_ERROR_STOP=1 -q | sha256sum | awk '{print $1}')"
    printf '%s\t%s\n' "$table" "$checksum" >>"$temporary_output"
  done <"$tables_file"
  mv "$temporary_output" "$output_file"
}

export_data() {
  local temporary_archive
  require_source_url
  mkdir -p "$ARTIFACT_DIR"
  temporary_archive="${ARCHIVE_PATH}.tmp"

  notice "Exporting Supabase public-schema data"
  pg_dump "$SOURCE_DATABASE_URL" \
    --format=custom \
    --data-only \
    --schema=public \
    --no-owner \
    --no-acl \
    --no-subscriptions \
    --file="$temporary_archive"
  mv "$temporary_archive" "$ARCHIVE_PATH"

  inventory_tables "$SOURCE_DATABASE_URL" >"$TABLES_PATH"
  collect_counts "$SOURCE_DATABASE_URL" "$TABLES_PATH" "$SOURCE_COUNTS_PATH"
  pg_restore --list "$ARCHIVE_PATH" >"$ARTIFACT_DIR/archive-contents.txt"

  notice "Archive: $ARCHIVE_PATH"
  notice "Source counts: $SOURCE_COUNTS_PATH"
  if [ "${MIGRATION_WRITERS_PAUSED:-NO}" != "YES" ]; then
    echo "warning: source writers were not attested as paused; counts may be newer than the dump snapshot" >&2
  fi
}

require_restore_confirmation() {
  local expected="The Social Wire/${RAILWAY_ENVIRONMENT}/${RAILWAY_POSTGRES_SERVICE}"
  [ "${MIGRATION_WRITERS_PAUSED:-}" = "YES" ] \
    || fail "set MIGRATION_WRITERS_PAUSED=YES only after pausing Supabase and Railway database writers"
  [ "${MIGRATION_CONFIRM_TARGET_RESET:-}" = "$expected" ] \
    || fail "set MIGRATION_CONFIRM_TARGET_RESET='$expected' to authorize truncating target application tables"
}

truncate_target_tables() {
  local table table_list=""
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    validate_table_name "$table"
    if [ -n "$table_list" ]; then
      table_list+=", "
    fi
    table_list+="public.\"$table\""
  done <"$TABLES_PATH"
  [ -n "$table_list" ] || fail "no public tables found in $TABLES_PATH"

  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -c "TRUNCATE TABLE $table_list RESTART IDENTITY CASCADE"
}

restore_data() {
  require_restore_confirmation
  [ -f "$ARCHIVE_PATH" ] || fail "missing archive: $ARCHIVE_PATH"
  [ -f "$TABLES_PATH" ] || fail "missing table inventory: $TABLES_PATH"
  resolve_target_url
  compare_schema_contract

  notice "Truncating Railway application tables"
  truncate_target_tables

  notice "Restoring data to Railway with $RESTORE_JOBS jobs"
  pg_restore \
    --dbname="$TARGET_DATABASE_URL" \
    --format=custom \
    --data-only \
    --no-owner \
    --no-acl \
    --disable-triggers \
    --jobs="$RESTORE_JOBS" \
    --exit-on-error \
    "$ARCHIVE_PATH"

  notice "Refreshing Railway query-planner statistics"
  psql "$TARGET_DATABASE_URL" -X -v ON_ERROR_STOP=1 -c "ANALYZE"
}

verify_data() {
  require_source_url
  [ -f "$TABLES_PATH" ] || fail "missing table inventory: $TABLES_PATH"
  resolve_target_url

  notice "Comparing exact table row counts"
  collect_counts "$SOURCE_DATABASE_URL" "$TABLES_PATH" "$SOURCE_COUNTS_PATH"
  collect_counts "$TARGET_DATABASE_URL" "$TABLES_PATH" "$TARGET_COUNTS_PATH"
  if ! diff -u "$SOURCE_COUNTS_PATH" "$TARGET_COUNTS_PATH"; then
    fail "source and target row counts differ"
  fi

  if [ "${MIGRATION_VERIFY_CHECKSUMS:-0}" = "1" ]; then
    notice "Comparing full row-content checksums; this scans and sorts every row hash"
    collect_checksums "$SOURCE_DATABASE_URL" "$TABLES_PATH" "$SOURCE_CHECKSUMS_PATH"
    collect_checksums "$TARGET_DATABASE_URL" "$TABLES_PATH" "$TARGET_CHECKSUMS_PATH"
    if ! diff -u "$SOURCE_CHECKSUMS_PATH" "$TARGET_CHECKSUMS_PATH"; then
      fail "source and target content checksums differ"
    fi
  fi

  notice "Data verification passed"
}

if [ "$COMMAND" = "help" ] || [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ]; then
  usage
  exit 0
fi

require_tool psql
require_tool pg_dump
require_tool pg_restore
require_tool jq
require_tool sha256sum

case "$COMMAND" in
  preflight)
    preflight
    ;;
  export)
    preflight
    export_data
    ;;
  restore)
    require_source_url
    restore_data
    ;;
  verify)
    verify_data
    ;;
  migrate)
    require_restore_confirmation
    preflight
    export_data
    restore_data
    verify_data
    ;;
  *)
    usage >&2
    fail "unknown command: $COMMAND"
    ;;
esac
