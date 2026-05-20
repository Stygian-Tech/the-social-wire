#!/usr/bin/env bash
# Run Supabase validate-migrations job locally (Docker-in-Docker: mounts host socket).
# Usage: bash scripts/act/run-supabase-validate.sh [-- OPTIONS_FOR_ACT...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! docker info &>/dev/null; then
  echo "error: Docker daemon not reachable (start Docker Desktop, then retry)." >&2
  exit 1
fi

AFTER="$(git rev-parse HEAD)"
BEFORE="$(git rev-parse "${AFTER}^" 2>/dev/null || printf '%s' '0000000000000000000000000000000000000000')"

EVENT="$(mktemp)"
cleanup() { rm -f "$EVENT"; }
trap cleanup EXIT

# Minimal pull_request payload so jobs with `if: github.event_name == pull_request` run under act.
printf '%s' "{\"action\":\"opened\",\"repository\":{\"default_branch\":\"main\"},\"pull_request\":{\"base\":{\"ref\":\"main\",\"sha\":\"${BEFORE}\"},\"head\":{\"ref\":\"act-local\",\"sha\":\"${AFTER}\"}}}" >"$EVENT"

echo "act: supabase validate-migrations (host docker.sock mounted into job container)" >&2
exec act pull_request \
  -W .github/workflows/ci.yml \
  -j supabase-validate \
  -e "$EVENT" \
  --reuse \
  --container-options "--privileged -v /var/run/docker.sock:/var/run/docker.sock" \
  "$@"
