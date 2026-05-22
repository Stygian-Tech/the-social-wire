#!/usr/bin/env bash
# Push supabase/migrations to a hosted project from CI or act.
#
# Required (link + password fallback only):
#   SUPABASE_ACCESS_TOKEN
#   REF                    — project ref (Settings → General)
#
# Preferred (Session pooler URI from Dashboard → Connect → Session mode, port 5432):
#   DATABASE_URL           — postgresql://postgres.[ref]:[pass]@…pooler.supabase.com:5432/postgres
#
# Fallback (when DATABASE_URL unset or unusable):
#   DB_PASSWORD            — plain Postgres password (must match Dashboard → Database)
#
# Usage:
#   REF=… DB_PASSWORD=… SUPABASE_ACCESS_TOKEN=… bash scripts/supabase-ci-push.sh dev
set -euo pipefail

ENV_LABEL="${1:?usage: supabase-ci-push.sh dev|prod}"

trim_secret() {
  local v="$1"
  v="$(printf '%s' "$v" | tr -d '\r\n')"
  printf '%s' "$v"
}

env_secret_name() {
  local suffix="$1"
  env_upper="$(printf '%s' "$ENV_LABEL" | tr '[:lower:]' '[:upper:]')"
  printf 'SUPABASE_%s_%s' "$env_upper" "$suffix"
}

# Direct db host (db.[ref].supabase.co) is often IPv6-only; GitHub Actions cannot reach it.
is_direct_supabase_db_url() {
  local url="$1"
  [[ "$url" =~ @db\.[^/@]+\.supabase\.co(:|/|$|\?) ]]
}

is_session_pooler_url() {
  local url="$1"
  [[ "$url" =~ pooler\.supabase\.(com|co)(:|/|$|\?) ]]
}

# Log host/user/port without credentials (safe for CI logs).
describe_database_url() {
  local url="$1"
  python3 - "$url" <<'PY' 2>/dev/null || printf 'configured (could not parse URI)'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
host = u.hostname or "(missing host)"
port = u.port or "(default)"
user = u.username or "(missing user)"
kind = "session pooler" if "pooler.supabase." in host else (
  "direct db host" if host.startswith("db.") and host.endswith(".supabase.co") else "other"
)
print(f"host={host} port={port} user={user} kind={kind}")
PY
}

resolve_push_database_url() {
  local url db_pass secret_name
  url="$(trim_secret "${DATABASE_URL:-}")"
  if [ -z "$url" ]; then
    return 0
  fi

  echo "::notice::$(env_secret_name DATABASE_URL) → $(describe_database_url "$url")" >&2

  if is_direct_supabase_db_url "$url"; then
    secret_name="$(env_secret_name DATABASE_URL)"
    echo "::warning::${secret_name} still uses direct db.*.supabase.co (IPv6 unreachable on GitHub Actions)." >&2
    echo "::warning::Replace ${secret_name} with the **Session pooler** URI from Dashboard → Connect → Session → port 5432 (host …pooler.supabase.com, user postgres.[ref])." >&2
    db_pass="$(trim_secret "${DB_PASSWORD:-}")"
    if [ -n "$db_pass" ]; then
      echo "::notice::Falling back to supabase link + $(env_secret_name DB_PASSWORD) (ensure it matches the rotated database password)." >&2
      return 0
    fi
    echo "::error::Set ${secret_name} to the session pooler URI, or set $(env_secret_name DB_PASSWORD). See supabase/README.md." >&2
    exit 1
  fi

  if ! is_session_pooler_url "$url"; then
    echo "::warning::DATABASE_URL host is not pooler.supabase.com — push may fail from CI." >&2
  fi

  printf '%s' "$url"
}

require_link_credentials() {
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    echo '::error::Missing SUPABASE_ACCESS_TOKEN.'
    exit 1
  fi
  if [ -z "${REF:-}" ]; then
    echo "::error::Missing project ref for ${ENV_LABEL} ($(env_secret_name PROJECT_REF))."
    exit 1
  fi
}

auth_failure_help() {
  local used_fallback="${1:-false}"
  echo '::error::db push failed (SQLSTATE 28P01 = password authentication failed).' >&2
  echo '::error::After a password reset, update **every** secret that carries the DB password:' >&2
  echo "::error::  • $(env_secret_name DATABASE_URL) — full session pooler URI from Connect (password embedded; URL-encode special chars)." >&2
  echo "::error::  • $(env_secret_name DB_PASSWORD) — plain password only (same value as in the URI)." >&2
  if [ "$used_fallback" = "true" ]; then
    echo "::error::Your $(env_secret_name DATABASE_URL) is still a direct db.* URL, so CI used the password fallback. Fix the pooler URI secret first." >&2
  fi
  echo '::error::Dashboard → Project Settings → Database → reset password if unsure, then re-copy Connect → Session URI.' >&2
}

push_via_database_url() {
  local url="$1"
  echo "::notice::db push → Supabase **${ENV_LABEL}** via session pooler DATABASE_URL"
  if supabase db push --db-url "$url" --yes; then
    return 0
  fi

  echo '::error::db push via DATABASE_URL failed.' >&2
  auth_failure_help false
  echo '::error::Confirm port **5432** (Session mode), user **postgres.[project-ref]**, and URL-encoded password in the URI.' >&2
  exit 1
}

push_via_link_and_password() {
  local db_pass used_fallback="false"
  db_pass="$(trim_secret "${DB_PASSWORD:-}")"
  if [ -z "$db_pass" ]; then
    echo "::error::Missing database credentials for ${ENV_LABEL}. Set $(env_secret_name DATABASE_URL) (session pooler) or $(env_secret_name DB_PASSWORD)." >&2
    exit 1
  fi

  if [ -n "$(trim_secret "${DATABASE_URL:-}")" ] && is_direct_supabase_db_url "$(trim_secret "${DATABASE_URL}")"; then
    used_fallback="true"
  fi

  require_link_credentials

  echo "::notice::db push → Supabase **${ENV_LABEL}** project ref ${REF} (link + password → pooler)"
  export SUPABASE_DB_PASSWORD="$db_pass"
  supabase link --project-ref "${REF}" --yes
  if ! supabase db push --yes; then
    auth_failure_help "$used_fallback"
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
