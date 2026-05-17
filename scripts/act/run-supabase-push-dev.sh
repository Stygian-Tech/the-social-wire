#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
SECRETS="${ACT_SECRETS_FILE:-$REPO_ROOT/scripts/act/.secrets}"
[[ -f "$SECRETS" ]] || { echo "error: missing $SECRETS"; exit 1; }
docker info &>/dev/null || { echo "error: Docker not running"; exit 1; }
AFTER="$(git rev-parse HEAD)"
BEFORE="$(git rev-parse "${AFTER}^" 2>/dev/null || printf '%s' '0000000000000000000000000000000000000000')"
EVENT="$(mktemp)"
trap 'rm -f "$EVENT"' EXIT
printf '{"ref":"refs/heads/dev","before":"%s","after":"%s","repository":{"default_branch":"main"}}\n' "$BEFORE" "$AFTER" >"$EVENT"
exec act push -W .github/workflows/supabase.yml -j push-migrations-dev -e "$EVENT" --secret-file "$SECRETS" --reuse "$@"
