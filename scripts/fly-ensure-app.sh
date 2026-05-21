#!/usr/bin/env bash
# Ensure a Fly app exists; create it when missing (used by deploy scripts and CI).
#
# Usage: bash scripts/fly-ensure-app.sh <app-name>
#
# Optional env:
#   FLY_ORG — Fly organization slug when the token has access to multiple orgs
set -euo pipefail

APP="${1:?usage: fly-ensure-app.sh <app-name>}"

ensure_flyctl() {
  if command -v flyctl >/dev/null 2>&1; then
    return 0
  fi
  if [ -x "${HOME}/.fly/bin/flyctl" ]; then
    export PATH="${HOME}/.fly/bin:${PATH}"
    return 0
  fi
  echo "::error::flyctl not found."
  exit 1
}

app_exists() {
  flyctl apps list --json 2>/dev/null | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
print('yes' if any(a.get('Name') == name or a.get('name') == name for a in data) else 'no')
" "$1"
}

ensure_flyctl

if [ "$(app_exists "$APP")" = "yes" ]; then
  echo "::notice::Fly app ${APP} already exists"
  exit 0
fi

echo "::notice::Fly app ${APP} not found — creating"
if [ -n "${FLY_ORG:-}" ]; then
  flyctl apps create "$APP" --org "$FLY_ORG"
else
  flyctl apps create "$APP"
fi

echo "::notice::Created Fly app ${APP}"
