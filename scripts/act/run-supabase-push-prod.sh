#!/usr/bin/env bash
# Simulates a push to main / dev for Supabase migration push jobs.
# Usage: bash scripts/act/run-supabase-push-prod.sh [-- act flags…]
#   -n / --dryrun — resolve workflow steps only (no containers, no secrets file needed).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
SECRETS="${ACT_SECRETS_FILE:-$REPO_ROOT/scripts/act/.secrets}"
DRY_RUN=0
for arg in "$@"; do
  if [[ "$arg" == "-n" || "$arg" == "--dryrun" ]]; then
    DRY_RUN=1
    break
  fi
done
if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -f "$SECRETS" ]] || { echo "error: missing $SECRETS (copy from scripts/act/.secrets.example)" >&2; exit 1; }
fi
docker info &>/dev/null || { echo "error: Docker not running"; exit 1; }
AFTER="$(git rev-parse HEAD)"
BEFORE="$(git rev-parse "${AFTER}^" 2>/dev/null || printf '%s' '0000000000000000000000000000000000000000')"
EVENT="$(mktemp)"
trap 'rm -f "$EVENT"' EXIT
printf '{"ref":"refs/heads/main","before":"%s","after":"%s","repository":{"default_branch":"main"}}\n' "$BEFORE" "$AFTER" >"$EVENT"
if [[ "$DRY_RUN" -eq 1 ]]; then
  exec act push -W .github/workflows/supabase.yml -j push-migrations-prod -e "$EVENT" --reuse "$@"
else
  exec act push -W .github/workflows/supabase.yml -j push-migrations-prod -e "$EVENT" --secret-file "$SECRETS" --reuse "$@"
fi
