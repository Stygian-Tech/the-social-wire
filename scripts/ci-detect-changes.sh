#!/usr/bin/env bash
# Detect changed path filters for CI (replaces dorny/paths-filter; no marketplace download).
set -euo pipefail

BASE=""
HEAD="${GITHUB_SHA:?GITHUB_SHA is required}"
MATCH_ALL=0

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    BASE="${GITHUB_EVENT_PULL_REQUEST_BASE_SHA:-}"
    if [ -z "$BASE" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
      BASE="$(git merge-base "$HEAD" "origin/${GITHUB_BASE_REF}")"
    fi
    if [ -z "$BASE" ]; then
      echo "Unable to determine pull request base SHA." >&2
      exit 1
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

# A workflow or detector change can affect any path decision. Exercise the whole
# matrix so the aggregate gate cannot go green with an untested CI change.
if [ "$MATCH_ALL" = "0" ] && ! git diff --quiet "$BASE" "$HEAD" -- \
  '.github/workflows/ci.yml' \
  'scripts/ci-detect-changes.sh'; then
  MATCH_ALL=1
fi

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
    if ! git diff --quiet "$BASE" "$HEAD" -- "$pathspec"; then
      echo "${name}=true" >> "$out"
      return
    fi
  done

  echo "${name}=false" >> "$out"
}

filter_changed web \
  'apps/web/**' \
  'packages/record-keys/**' \
  'package.json' \
  'bun.lock' \
  'turbo.json' \
  'scripts/check-bun-coverage-inventory.ts' \
  'railway/web.json' \
  '.github/workflows/ci.yml'

filter_changed operations_web \
  'apps/operations/**' \
  'docs/runbooks/operations/**' \
  'package.json' \
  'bun.lock' \
  'turbo.json' \
  'scripts/check-bun-coverage-inventory.ts' \
  'railway/operations-web.json' \
  '.github/workflows/ci.yml'

filter_changed apple \
  'apps/apple/**' \
  '.github/workflows/ci.yml'

filter_changed operations \
  'services/operations/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'packages/swift/OperationsCore/**' \
  'railway/operations.json' \
  '.github/workflows/ci.yml'

filter_changed redis \
  'packages/swift/SocialWireRedis/**' \
  '.github/workflows/ci.yml'

filter_changed gateway \
  'services/gateway/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'railway/gateway.json' \
  '.github/workflows/ci.yml'

filter_changed appview \
  'services/appview/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'railway/appview.json' \
  '.github/workflows/ci.yml'

filter_changed charybdis \
  'services/appview-worker/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'railway/charybdis.json' \
  '.github/workflows/ci.yml'

filter_changed jetstream_ingest \
  'services/jetstream-ingest/**' \
  'database/migrations/**' \
  'packages/swift/ThinAppViewCore/Tests/ThinAppViewCoreTests/Fixtures/jetstream-v2-go-sdk-v0.2.0-events.json' \
  'railway/jetstream-ingest.json' \
  '.github/workflows/ci.yml'

filter_changed database_migrator \
  'database/migrations/**' \
  'scripts/apply-database-migrations.sh' \
  'scripts/verify-jetstream-v2-drain-indexes.sql' \
  'services/database-migrator/**' \
  'railway/database-migrator.json' \
  '.github/workflows/ci.yml'

filter_changed lexicons \
  'packages/lexicons/**' \
  'packages/spec/endpoint-manifest.json' \
  'package.json' \
  'bun.lock' \
  '.github/workflows/ci.yml'

filter_changed spec \
  'packages/spec/**' \
  'packages/lexicons/**' \
  'apps/web/**' \
  'apps/apple/**' \
  'railway/**' \
  '**/migrations/**' \
  'services/**/bruno/**' \
  'services/gateway/Sources/Gateway/**' \
  'services/appview/Sources/AppView/**' \
  'services/operations/Sources/Operations/**' \
  'services/jetstream-ingest/internal/config/config.go' \
  'services/jetstream-ingest/internal/store/postgres.go' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/OperationsCore/**' \
  'scripts/apply-database-migrations.sh' \
  'scripts/verify-jetstream-v2-drain-indexes.sql' \
  'scripts/operations/**' \
  'package.json' \
  'bun.lock' \
  '.github/workflows/ci.yml'

filter_changed docs \
  'docs/wiki/**' \
  'scripts/check-wiki-links.sh' \
  '.github/workflows/ci.yml'
