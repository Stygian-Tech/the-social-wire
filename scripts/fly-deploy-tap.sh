#!/usr/bin/env bash
# Manually deploy the environment-isolated Tap service.
# Usage: bash scripts/fly-deploy-tap.sh dev|main
set -euo pipefail

BRANCH="${1:?usage: fly-deploy-tap.sh dev|main}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo '::error::Missing FLY_API_TOKEN.'
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "::notice::Fly Tap deploy (${BRANCH}); acknowledgement mode remains enabled"
exec bash "$ROOT/services/tap/deploy.sh" "$BRANCH"
