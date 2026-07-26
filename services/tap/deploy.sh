#!/usr/bin/env bash
# Deploy the environment-isolated Tap service from the monorepo root.
# Usage: bash services/tap/deploy.sh dev|main
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SERVICE_DIR/../.." && pwd)"
BRANCH="${1:?usage: deploy.sh dev|main}"

if [ "$BRANCH" = "main" ]; then
  CONFIG="services/tap/fly.prod.toml"
  APP="the-social-wire-prod-tap"
else
  CONFIG="services/tap/fly.toml"
  APP="the-social-wire-dev-tap"
fi

cd "$ROOT"
bash "$ROOT/scripts/fly-ensure-app.sh" "$APP"
exec flyctl deploy . --config "$CONFIG" --app "$APP" --local-only
