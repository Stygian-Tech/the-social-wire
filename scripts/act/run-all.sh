#!/usr/bin/env bash
# Run local act checks that do not require repository secrets (Docker + image pull required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
bash "$ROOT/scripts/act/run-ci.sh"
bash "$ROOT/scripts/act/run-supabase-validate.sh"
echo "ok: act CI + supabase validate (no deploy / remote push). For Fly or remote db push, use scripts/act/.secrets + run-deploy.sh / run-supabase-push-*.sh" >&2
