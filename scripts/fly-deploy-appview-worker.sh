#!/usr/bin/env bash
# Deploy services/appview-worker to Fly.io for dev or main.
#
# Requires: FLY_API_TOKEN, FLY_APPVIEW_WORKER_APP_* (or FLY_WORKER_APP_*).
# Usage: bash scripts/fly-deploy-appview-worker.sh dev|main
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-appview-worker.sh dev|main}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "::notice::Fly appview-worker deploy (${BRANCH})"
exec bash "$ROOT/services/appview-worker/deploy.sh" "$BRANCH"
