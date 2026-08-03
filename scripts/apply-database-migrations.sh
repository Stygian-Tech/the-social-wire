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

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
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

for migration in "${migrations[@]}"; do
  filename="$(basename "$migration")"
  version="${filename%%_*}"
  if psql "$DATABASE_URL" -X -Atqc \
    "SELECT 1 FROM public.schema_migrations WHERE version = '$version'" | grep -qx 1; then
    echo "skip $filename"
    continue
  fi

  echo "apply $filename"
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f "$migration"
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -v migration_version="$version" -v migration_name="$filename" <<'SQL'
INSERT INTO public.schema_migrations (version, name)
VALUES (:'migration_version', :'migration_name')
ON CONFLICT (version) DO NOTHING;
SQL
done
