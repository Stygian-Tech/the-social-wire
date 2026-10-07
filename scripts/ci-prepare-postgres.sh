#!/usr/bin/env bash
# CI uses the production migration runner against disposable job databases.
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL is required}"
case "${VERIFY_IDEMPOTENCE:-false}" in
  true|false) ;;
  *) echo "VERIFY_IDEMPOTENCE must be true or false" >&2; exit 1 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT_DIR/scripts/apply-database-migrations.sh"
if [[ "${VERIFY_IDEMPOTENCE:-false}" == "true" ]]; then
  bash "$ROOT_DIR/scripts/apply-database-migrations.sh"
fi
