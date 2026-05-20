#!/usr/bin/env bash
# Block until Supabase migration workflow finishes for this commit (when required).
#
# Exit 0 — not required, or Supabase succeeded.
# Exit 1 — Supabase failed or timed out.
#
# Usage:
#   GITHUB_REPOSITORY=owner/repo GH_TOKEN=… \
#     bash scripts/wait-for-supabase-ci.sh <sha>
set -euo pipefail

SHA="${1:?sha required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
export GH_TOKEN="${GH_TOKEN:?GH_TOKEN required}"

MAX_WAIT_SEC="${MAX_WAIT_SEC:-1500}"
POLL_SEC="${POLL_SEC:-20}"

commit_touches_supabase() {
  if ! git cat-file -e "${SHA}^" 2>/dev/null; then
    return 1
  fi
  git diff --name-only "${SHA}^" "$SHA" | grep -Eq \
    '^(supabase/|\.github/workflows/ci\.yml|scripts/supabase-ci-push\.sh)'
}

supabase_run_line() {
  gh run list \
    --repo "$REPO" \
    --workflow CI \
    --commit "$SHA" \
    --event push \
    --limit 1 \
    --json status,conclusion \
    -q '.[0] | "\(.status // "")\t\(.conclusion // "")"' 2>/dev/null || printf '\t'
}

if ! commit_touches_supabase; then
  echo "→ Supabase: not required for ${SHA}"
  exit 0
fi

echo "→ Supabase: waiting for migration workflow on ${SHA}"
deadline=$((SECONDS + MAX_WAIT_SEC))

while [ "$SECONDS" -lt "$deadline" ]; do
  line="$(supabase_run_line)"
  status="${line%%$'\t'*}"
  conclusion="${line#*$'\t'}"

  if [ -z "$status" ] || [ "$status" = "null" ]; then
    echo "… no Supabase run yet (${SECONDS}s)"
    sleep "$POLL_SEC"
    continue
  fi

  case "$status" in
    queued | in_progress | pending | waiting | requested)
      echo "… Supabase ${status} (${SECONDS}s)"
      sleep "$POLL_SEC"
      ;;
    completed)
      if [ "$conclusion" = "success" ]; then
        echo "→ Supabase: success"
        exit 0
      fi
      echo "::error::Supabase workflow failed (conclusion=${conclusion})."
      exit 1
      ;;
    *)
      echo "::error::Unexpected Supabase status: ${status}"
      exit 1
      ;;
  esac
done

echo "::error::Timed out waiting for Supabase workflow (${MAX_WAIT_SEC}s)."
exit 1
