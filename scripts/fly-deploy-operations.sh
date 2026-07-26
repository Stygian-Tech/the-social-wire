#!/usr/bin/env bash
# Deploy the independent operations control plane to Fly.io.
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-operations.sh dev|main}"
if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi
if [ -z "${SUPABASE_DATABASE_URL:-}" ]; then
  echo '::error::Missing SUPABASE_DATABASE_URL.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$BRANCH" = "main" ]; then
  APP="${FLY_OPERATIONS_APP_PROD:-the-social-wire-prod-operations}"
else
  APP="${FLY_OPERATIONS_APP_DEV:-the-social-wire-dev-operations}"
fi

echo "::notice::Fly operations deploy (${BRANCH})"
flyctl secrets set --stage --app "$APP" "SUPABASE_DATABASE_URL=$SUPABASE_DATABASE_URL"
exec bash "$ROOT/services/operations/deploy.sh" "$BRANCH"
