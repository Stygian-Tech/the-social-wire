#!/usr/bin/env bash
# Apply provider-neutral Postgres migrations exactly once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$ROOT/database/migrations}"
DATABASE_URL="${DATABASE_URL:?DATABASE_URL is required}"

command -v psql >/dev/null 2>&1 || {
  echo 'error: psql is required.' >&2
  exit 1
}

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction <<'SQL'
SELECT pg_advisory_xact_lock(hashtextextended('the-social-wire-schema-migrations', 0));
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL

shopt -s nullglob
migrations=("$MIGRATIONS_DIR"/*.sql)
if (( ${#migrations[@]} == 0 )); then
  echo "error: no migrations found in $MIGRATIONS_DIR" >&2
  exit 1
fi

migration_run_dir="$(mktemp -d)"
trap 'rm -rf "$migration_run_dir"' EXIT

append_migration_body() {
  local migration="$1"
  # Some applied historical files carry their own outer BEGIN/COMMIT wrapper. Keeping that
  # wrapper would commit and release our transaction-scoped advisory lock before the runner
  # records schema_migrations. Remove only a file-wide outer wrapper in the temporary copy;
  # nested PL/pgSQL BEGIN blocks and the checked-in migration history remain untouched.
  awk '
    function normalized(line, value) {
      value = line
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return toupper(value)
    }
    function significant(line, value) {
      value = line
      sub(/^[[:space:]]+/, "", value)
      return value != "" && value !~ /^--/
    }
    {
      lines[NR] = $0
      if (significant($0)) {
        if (first == 0) first = NR
        last = NR
      }
    }
    END {
      strip = first > 0 && normalized(lines[first]) ~ /^BEGIN;?$/ &&
        normalized(lines[last]) ~ /^COMMIT;?$/
      for (line = 1; line <= NR; line++) {
        if (strip && (line == first || line == last)) continue
        print lines[line]
      }
    }
  ' "$migration"
}

for migration in "${migrations[@]}"; do
  filename="$(basename "$migration")"
  version="${filename%%_*}"
  transaction_file="$migration_run_dir/$filename"
  transaction_setting="$(
    sed -nE \
      's/^[[:space:]]*--[[:space:]]*socialwire:transaction=(on|off)[[:space:]]*$/\1/p' \
      "$migration"
  )"
  if grep -Eq '^[[:space:]]*--[[:space:]]*socialwire:transaction' "$migration"; then
    case "$transaction_setting" in
      on|off) ;;
      *)
        echo "error: $filename has an invalid or duplicate socialwire:transaction directive." >&2
        exit 1
        ;;
    esac
  else
    transaction_setting="on"
  fi

  {
    if [ "$transaction_setting" = "off" ]; then
      cat <<'SQL'
-- A session-level lock spans every autocommitted statement in this migration.
-- PostgreSQL releases it automatically if psql exits after a failed statement.
SELECT pg_advisory_lock(hashtextextended('the-social-wire-schema-migrations', 0));
SQL
    else
      cat <<'SQL'
SELECT pg_advisory_xact_lock(hashtextextended('the-social-wire-schema-migrations', 0));
SQL
    fi
    cat <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM public.schema_migrations
  WHERE version = :'migration_version'
) AS migration_applied
\gset
\if :migration_applied
\echo skip :migration_name
\else
\echo apply :migration_name
SQL
    append_migration_body "$migration"
    printf '\n'
    cat <<'SQL'
INSERT INTO public.schema_migrations (version, name)
VALUES (:'migration_version', :'migration_name');
\endif
SQL
    if [ "$transaction_setting" = "off" ]; then
      cat <<'SQL'
SELECT pg_advisory_unlock(hashtextextended('the-social-wire-schema-migrations', 0));
SQL
    fi
  } >"$transaction_file"

  if [ "$transaction_setting" = "off" ]; then
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
      -v migration_version="$version" -v migration_name="$filename" \
      -f "$transaction_file"
  else
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction \
      -v migration_version="$version" -v migration_name="$filename" \
      -f "$transaction_file"
  fi
done
