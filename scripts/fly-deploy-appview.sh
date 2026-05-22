#!/usr/bin/env bash
# Deploy services/appview to Fly.io for dev or main.
#
# Requires: FLY_API_TOKEN, FLY_APPVIEW_APP_DEV / FLY_APPVIEW_APP_PROD.
# Usage: bash scripts/fly-deploy-appview.sh dev|main
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-appview.sh dev|main}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "::notice::Fly appview deploy (${BRANCH})"
exec bash "$ROOT/services/appview/deploy.sh" "$BRANCH"
