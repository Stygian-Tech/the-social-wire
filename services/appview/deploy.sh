#!/usr/bin/env bash
# Deploy AppView from monorepo root (Docker build context = repo root).
#
# Usage: bash deploy.sh dev|main
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
BRANCH="${1:?usage: deploy.sh dev|main}"

if [ "$BRANCH" = "main" ]; then
  CONFIG="services/appview/fly.prod.toml"
  APP="${FLY_APPVIEW_APP_PROD:-the-social-wire-prod-appview}"
else
  CONFIG="services/appview/fly.toml"
  APP="${FLY_APPVIEW_APP_DEV:-the-social-wire-dev-appview}"
fi

cd "$ROOT"
bash "$ROOT/scripts/fly-ensure-app.sh" "$APP"
exec flyctl deploy . --config "$CONFIG" --app "$APP" --local-only
