#!/usr/bin/env bash
# Deploy services/gateway to Fly.io for dev or main.
#
# Requires: FLY_API_TOKEN, FLY_GATEWAY_APP_DEV / FLY_GATEWAY_APP_PROD (or FLY_APP_*).
# Usage: bash scripts/fly-deploy-gateway.sh dev|main
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-gateway.sh dev|main}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "::notice::Fly gateway deploy (${BRANCH})"
exec bash "$ROOT/services/gateway/deploy.sh" "$BRANCH"
