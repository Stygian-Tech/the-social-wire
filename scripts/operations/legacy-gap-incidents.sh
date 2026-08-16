#!/usr/bin/env bash
set -euo pipefail

mode="report"
if [[ "${1:-}" == "--apply" ]]; then
  mode="apply"
elif [[ -n "${1:-}" && "${1:-}" != "--report" ]]; then
  echo "Usage: $0 [--report|--apply]" >&2
  exit 64
fi

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${APP_ENV:?APP_ENV is required (dev or prod)}"
if [[ "$APP_ENV" != "dev" && "$APP_ENV" != "prod" ]]; then
  echo "APP_ENV must be dev or prod" >&2
  exit 64
fi

apply_mode=0
operator_did=""
if [[ "$mode" == "apply" ]]; then
  : "${OPERATIONS_OPERATOR_DID:?OPERATIONS_OPERATOR_DID is required for audited consolidation}"
  if [[ "${LEGACY_GAP_CONSOLIDATION_CONFIRM:-}" != "$APP_ENV" ]]; then
    echo "Set LEGACY_GAP_CONSOLIDATION_CONFIRM=$APP_ENV to apply consolidation" >&2
    exit 64
  fi
  apply_mode=1
  operator_did="$OPERATIONS_OPERATOR_DID"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec psql "$DATABASE_URL" \
  --set=ON_ERROR_STOP=1 \
  --set=target_environment="$APP_ENV" \
  --set=apply_mode="$apply_mode" \
  --set=operator_did="$operator_did" \
  --file="$script_dir/legacy-gap-incidents.sql"
