#!/usr/bin/env bash
# Deploy Charybdis from services/appview-worker to Fly.io for dev or main.
#
# Requires: FLY_API_TOKEN and optional FLY_APPVIEW_WORKER_APP_DEV / FLY_APPVIEW_WORKER_APP_PROD overrides.
# Usage: bash scripts/fly-deploy-appview-worker.sh dev|main
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-appview-worker.sh dev|main}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "::notice::Fly Charybdis deploy (${BRANCH}; appview-worker compatibility ID)"
exec bash "$ROOT/services/appview-worker/deploy.sh" "$BRANCH"
