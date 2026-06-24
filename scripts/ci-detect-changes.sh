#!/usr/bin/env bash
# Detect changed path filters for CI (replaces dorny/paths-filter; no marketplace download).
set -euo pipefail

BASE=""
HEAD="${GITHUB_SHA:?GITHUB_SHA is required}"
MATCH_ALL=0

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    BASE="${GITHUB_EVENT_PULL_REQUEST_BASE_SHA:-}"
    if [ -z "$BASE" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
      BASE="$(node -e "const fs=require('fs'); const event=JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH,'utf8')); process.stdout.write(event.pull_request?.base?.sha || '')")"
    fi
    if [ -z "$BASE" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
      BASE="$(git merge-base "HEAD" "origin/${GITHUB_BASE_REF}")"
    fi
    if [ -z "$BASE" ]; then
      echo "Unable to determine pull request base SHA; matching all paths." >&2
      MATCH_ALL=1
    fi
    ;;
  push)
    BASE="${GITHUB_EVENT_BEFORE:-}"
    if [ -z "$BASE" ] || [ "$BASE" = "0000000000000000000000000000000000000000" ]; then
      MATCH_ALL=1
    fi
    ;;
  *)
    MATCH_ALL=1
    ;;
esac

to_pathspec() {
  local spec="$1"
  if [[ "$spec" == *"*"* ]]; then
    printf ':(glob)%s' "$spec"
  else
    printf '%s' "$spec"
  fi
}

filter_changed() {
  local name="$1"
  shift
  local out="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

  if [ "$MATCH_ALL" = "1" ]; then
    echo "${name}=true" >> "$out"
    return
  fi

  local spec pathspec
  for spec in "$@"; do
    pathspec="$(to_pathspec "$spec")"
    if git diff --name-only "$BASE" "$HEAD" -- "$pathspec" | grep -q .; then
      echo "${name}=true" >> "$out"
      return
    fi
  done

  echo "${name}=false" >> "$out"
}

filter_changed web \
  'apps/web/**' \
  'packages/**' \
  'package.json' \
  'bun.lock' \
  'turbo.json' \
  '.github/workflows/ci.yml'

filter_changed gateway \
  'services/gateway/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'scripts/fly-deploy-gateway.sh' \
  '.github/workflows/ci.yml'

filter_changed appview \
  'services/appview/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'supabase/**' \
  'scripts/fly-deploy-appview.sh' \
  '.github/workflows/ci.yml'

filter_changed appview-worker \
  'services/appview-worker/**' \
  'packages/swift/ThinAppViewCore/**' \
  'supabase/**' \
  'scripts/fly-deploy-appview-worker.sh' \
  '.github/workflows/ci.yml'

filter_changed supabase \
  'supabase/**' \
  'scripts/supabase-ci-push.sh' \
  '.github/workflows/ci.yml'

filter_changed lexicons \
  'packages/lexicons/**' \
  '.github/workflows/ci.yml'

filter_changed spec \
  'packages/spec/**' \
  'services/gateway/Sources/Gateway/**' \
  'services/appview/Sources/AppView/**' \
  'packages/swift/GatewayCore/**' \
  '.github/workflows/ci.yml'
