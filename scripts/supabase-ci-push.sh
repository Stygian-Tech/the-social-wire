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

# Direct db host (db.[ref].supabase.co) is often IPv6-only; GitHub Actions cannot reach it.
is_direct_supabase_db_url() {
  local url="$1"
  [[ "$url" =~ @db\.[^/@]+\.supabase\.co(:|/|$|\?) ]]
}

resolve_push_database_url() {
  local url db_pass
  url="$(trim_secret "${DATABASE_URL:-}")"
  if [ -z "$url" ]; then
    return 0
  fi

  if is_direct_supabase_db_url "$url"; then
    echo "::warning::DATABASE_URL uses direct host db.*.supabase.co; GitHub Actions often cannot reach it (IPv6)." >&2
    db_pass="$(trim_secret "${DB_PASSWORD:-}")"
    if [ -n "$db_pass" ]; then
      echo "::notice::Ignoring direct DATABASE_URL; falling back to supabase link + DB_PASSWORD." >&2
      return 0
    fi
    env_upper="$(printf '%s' "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')"
    echo "::error::SUPABASE_${env_upper}_DATABASE_URL must be the **Session pooler** URI from Connect (host contains pooler.supabase.com, port 5432), not db.*.supabase.co." >&2
    echo "::error::Or unset DATABASE_URL and set SUPABASE_${env_upper}_DB_PASSWORD instead. See services/api/README.md." >&2
    exit 1
  fi

  printf '%s' "$url"
}

require_link_credentials() {
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    echo '::error::Missing SUPABASE_ACCESS_TOKEN.'
    exit 1
  fi
  if [ -z "${REF:-}" ]; then
    echo "::error::Missing project ref for ${ENV_LABEL}."
    exit 1
  fi
}

push_via_database_url() {
  local url="$1"
  echo "::notice::db push → Supabase **${ENV_LABEL}** via DATABASE_URL (session pooler)"
  if supabase db push --db-url "$url" --yes; then
    return 0
  fi

  echo '::error::db push via DATABASE_URL failed.'
  echo '::error::Confirm the URI is the **Session pooler** string from Supabase Connect (port 5432), not db.*.supabase.co.'
  echo '::error::network is unreachable / IPv6 errors mean the direct DB host was used; pooler URLs avoid that on GitHub Actions.'
  exit 1
}

push_via_link_and_password() {
  local db_pass
  db_pass="$(trim_secret "${DB_PASSWORD:-}")"
  if [ -z "$db_pass" ]; then
    env_upper="$(printf '%s' "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')"
    echo "::error::Missing database credentials for ${ENV_LABEL}. Set SUPABASE_${env_upper}_DATABASE_URL (session pooler) or SUPABASE_${env_upper}_DB_PASSWORD."
    exit 1
  fi

  require_link_credentials

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

run_push() {
  local url
  url="$(resolve_push_database_url)"
  if [ -n "$url" ]; then
    push_via_database_url "$url"
    return 0
  fi

  push_via_link_and_password
}

run_push
