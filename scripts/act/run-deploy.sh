#!/usr/bin/env bash
# Run deploy + supabase push jobs locally (requires real secrets).
# Copy to .secrets and fill: https://nektosact.com/secrets/
#   FLY_API_TOKEN=
#   FLY_APP_PROD=
#   SUPABASE_ACCESS_TOKEN=
#   SUPABASE_PROD_PROJECT_REF=
#   SUPABASE_PROD_DB_PASSWORD=
#
# Usage:
#   bash scripts/act/run-deploy.sh
#   bash scripts/act/run-supabase-push-prod.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SECRETS="${ACT_SECRETS_FILE:-$REPO_ROOT/scripts/act/.secrets}"
if [[ ! -f "$SECRETS" ]]; then
  echo "error: missing $SECRETS — copy scripts/act/.secrets.example and set values." >&2
  exit 1
fi

if ! docker info &>/dev/null; then
  echo "error: Docker daemon not reachable." >&2
  exit 1
fi

EVENT="$(mktemp)"
cleanup() { rm -f "$EVENT"; }
trap cleanup EXIT
printf '{"ref":"refs/heads/main","inputs":{}}\n' >"$EVENT"

exec act workflow_dispatch -W .github/workflows/deploy.yml -e "$EVENT" --secret-file "$SECRETS" --reuse "$@"
