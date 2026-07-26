#!/usr/bin/env bash
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
BRANCH="${1:?usage: deploy.sh dev|main}"

if [ "$BRANCH" = "main" ]; then
  CONFIG="services/operations/fly.prod.toml"
  APP="${FLY_OPERATIONS_APP_PROD:-the-social-wire-prod-operations}"
else
  CONFIG="services/operations/fly.toml"
  APP="${FLY_OPERATIONS_APP_DEV:-the-social-wire-dev-operations}"
fi

cd "$ROOT"
bash "$ROOT/scripts/fly-ensure-app.sh" "$APP"
exec flyctl deploy . --config "$CONFIG" --app "$APP" --local-only
