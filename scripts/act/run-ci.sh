#!/usr/bin/env bash
# Run GitHub CI workflow locally with nektos/act (requires Docker running).
# Usage (from repo root): bash scripts/act/run-ci.sh [-- OPTIONS_FOR_ACT...]
# See https://github.com/nektos/act
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! docker info &>/dev/null; then
  echo "error: Docker daemon not reachable (start Docker Desktop, then retry)." >&2
  exit 1
fi

AFTER="$(git rev-parse HEAD)"
if BEFORE="$(git rev-parse "${AFTER}^" 2>/dev/null)"; then
  :
else
  BEFORE="0000000000000000000000000000000000000000"
fi

EVENT="$(mktemp)"
cleanup() { rm -f "$EVENT"; }
trap cleanup EXIT

printf '{"ref":"refs/heads/main","before":"%s","after":"%s","repository":{"default_branch":"main"}}\n' "$BEFORE" "$AFTER" >"$EVENT"

echo "act: simulated push $BEFORE -> $AFTER (CI path filter)" >&2
exec act push -W .github/workflows/ci.yml -e "$EVENT" --reuse "$@"
