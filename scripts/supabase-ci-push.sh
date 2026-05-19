#!/usr/bin/env bash
# Push supabase/migrations to a hosted project from CI or act.
#
# Required:
#   SUPABASE_ACCESS_TOKEN
#   REF                    — project ref (Settings → General)
#
# Preferred (Session pooler URI from Dashboard → Connect):
#   DATABASE_URL           — e.g. postgresql://postgres.[ref]:[pass]@…pooler…:5432/postgres
#
# Fallback:
#   DB_PASSWORD            — plain Postgres password (not a full URI)
#
# Usage:
#   REF=… DB_PASSWORD=… SUPABASE_ACCESS_TOKEN=… bash scripts/supabase-ci-push.sh dev
set -euo pipefail

ENV_LABEL="${1:?usage: supabase-ci-push.sh dev|prod}"

trim_secret() {
  local v="$1"
  v="$(printf '%s' "$v" | tr -d '\r')"
  printf '%s' "${v%$'\n'}"
}

has_database_url() {
  local url
  url="$(trim_secret "${DATABASE_URL:-}")"
  [ -n "$url" ]
}

if ! has_database_url; then
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    echo '::error::Missing SUPABASE_ACCESS_TOKEN.'
    exit 1
  fi
  if [ -z "${REF:-}" ]; then
    echo "::error::Missing project ref for ${ENV_LABEL}."
    exit 1
  fi
fi

run_push() {
  if [ -n "${DATABASE_URL:-}" ]; then
    local url
    url="$(trim_secret "$DATABASE_URL")"
    if [ -n "$url" ]; then
      echo "::notice::db push → Supabase **${ENV_LABEL}** via DATABASE_URL (session pooler)"
      supabase db push --db-url "$url" --yes
      return 0
    fi
  fi

  local db_pass
  db_pass="$(trim_secret "${DB_PASSWORD:-}")"
  if [ -z "$db_pass" ]; then
    env_upper="$(printf '%s' "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')"
    echo "::error::Missing database credentials for ${ENV_LABEL}. Set SUPABASE_${env_upper}_DATABASE_URL (preferred) or SUPABASE_${env_upper}_DB_PASSWORD."
    exit 1
  fi

  echo "::notice::db push → Supabase **${ENV_LABEL}** project ref ${REF}"
  export SUPABASE_DB_PASSWORD="$db_pass"
  supabase link --project-ref "${REF}" --yes
  if ! supabase db push --yes; then
    echo '::error::db push failed (SQLSTATE 28P01 usually means the Postgres password secret is wrong or stale).'
    echo '::error::In Supabase Dashboard → Project Settings → Database, confirm or reset the password, then update GitHub Actions secrets.'
    echo '::error::Prefer SUPABASE_*_DATABASE_URL: copy the **Session pooler** URI from Connect (port 5432). See services/api/README.md.'
    exit 1
  fi
}

run_push
