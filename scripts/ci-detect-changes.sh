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
  'scripts/ci-detect-changes.sh' \
  'scripts/ci-prepare-postgres.sh' \
  '.github/actions/prepare-postgres'; then
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
  'packages/read-state/**' \
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
  'packages/swift/ReadStateCore/**' \
  '.github/workflows/ci.yml'

# Shared Go manifests also affect Swift images because their Go schema gate
# resolves the local module. Keep those image checks in sync with Docker COPY.

filter_changed operations \
  'packages/go/go.mod' \
  'packages/go/go.sum' \
  'database/migrations/**' \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/jetstream-ingest/go.mod' \
  'services/jetstream-ingest/go.sum' \
  'services/operations/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/ReadStateCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'packages/swift/OperationsCore/**' \
  'railway/operations.json' \
  '.github/workflows/ci.yml'

filter_changed redis \
  'packages/swift/SocialWireRedis/**' \
  '.github/workflows/ci.yml'

filter_changed gateway \
  'packages/go/go.mod' \
  'packages/go/go.sum' \
  'database/migrations/**' \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/jetstream-ingest/go.mod' \
  'services/jetstream-ingest/go.sum' \
  'services/gateway/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/ReadStateCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'packages/swift/WireCore/**' \
  'packages/swift/FinanceCore/**' \
  'packages/swift/SportsCore/**' \
  'railway/gateway.json' \
  '.github/workflows/ci.yml'

filter_changed appview \
  'packages/go/go.mod' \
  'packages/go/go.sum' \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/jetstream-ingest/go.mod' \
  'services/jetstream-ingest/go.sum' \
  'services/appview/**' \
  'database/migrations/**' \
  'packages/swift/GatewayCore/**' \
  'packages/swift/ThinAppViewCore/**' \
  'packages/swift/ReadStateCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'packages/swift/WireCore/**' \
  'packages/swift/FinanceCore/**' \
  'packages/swift/SportsCore/**' \
  'railway/appview.json' \
  '.github/workflows/ci.yml'



filter_changed jetstream_ingest \
  'packages/go/**' \
  'services/jetstream-ingest/**' \
  'database/migrations/**' \
  'packages/swift/ThinAppViewCore/Tests/ThinAppViewCoreTests/Fixtures/jetstream-v2-go-sdk-v0.2.0-events.json' \
  'railway/jetstream-ingest.json' \
  '.railway/**' \
  '.github/workflows/ci.yml'

filter_changed wire_ingest \
  'packages/go/**' \
  'services/jetstream-ingest/**' \
  'database/migrations/**' \
  'railway/wire-jetstream-ingest.json' \
  '.github/workflows/ci.yml'



filter_changed indexing_worker \
  'packages/go/**' \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/jetstream-ingest/go.mod' \
  'services/jetstream-ingest/go.sum' \
  'services/indexing-worker/**' \
  'database/migrations/**' \
  '.railway/**' \
  '.github/workflows/ci.yml'

filter_changed wire_corpus_edge \
  'services/wire-corpus-edge/**' \
  'packages/swift/WireCore/**' \
  'packages/swift/FinanceCore/**' \
  'packages/swift/SportsCore/**' \
  'packages/swift/SocialWireRedis/**' \
  'database/migrations/**' \
  'scripts/verify-wire-corpus-serving.sql' \
  'railway/wire-corpus-edge.json' \
  '.github/workflows/ci.yml'

filter_changed database_migrator \
  'database/migrations/**' \
  'scripts/apply-database-migrations.sh' \
  'scripts/verify-postgres-restore.sh' \
  'scripts/verify-jetstream-v2-drain-indexes.sql' \
  'scripts/verify-wire-inbox-claim-index.sql' \
  'scripts/operations/wire-inbox-readiness.sql' \
  'packages/spec/__tests__/wire-inbox-readiness-postgres.test.ts' \
  'scripts/verify-wire-corpus-serving.sql' \
  'services/database-migrator/**' \
  'services/postgres/**' \
  'railway/postgres.json' \
  'railway/database-migrator.json' \
  '.github/workflows/ci.yml'

filter_changed lexicons \
  'packages/lexicons/**' \
  'packages/spec/endpoint-manifest.json' \
  'package.json' \
  'bun.lock' \
  '.github/workflows/ci.yml'

filter_changed spec \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/*/Dockerfile' \
  'packages/read-state/**' \
  'packages/spec/**' \
  'scripts/benchmarks/**' \
  'scripts/capture-postgres-cost.sql' \
  'scripts/verify-postgres-restore.sh' \
  '.railway/**' \
  'docs/runbooks/operations/jetstream-v2-durable-replay.md' \
  'packages/lexicons/**' \
  'apps/web/**' \
  'apps/apple/**' \
  'packages/swift/ReadStateCore/**' \
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
  'packages/swift/ReadStateCore/**' \
  'packages/swift/OperationsCore/**' \
  'packages/swift/WireCore/**' \
  'packages/swift/FinanceCore/**' \
  'packages/swift/SportsCore/**' \
  'services/wire-corpus-edge/**' \
  'scripts/apply-database-migrations.sh' \
  'scripts/verify-jetstream-v2-drain-indexes.sql' \
  'scripts/verify-wire-corpus-serving.sql' \
  'scripts/operations/**' \
  'package.json' \
  'bun.lock' \
  '.github/workflows/ci.yml'

filter_changed docs \
  'docs/wiki/**' \
  'scripts/check-wiki-links.sh' \
  '.github/workflows/ci.yml'

filter_changed benchmark_tools \
  'scripts/benchmarks/**' \
  '.github/workflows/ci.yml'

filter_changed podcast_worker \
  'packages/go/go.mod' \
  'packages/go/go.sum' \
  'services/podcast-worker/**' \
  'services/jetstream-ingest/cmd/schema-ready/**' \
  'services/jetstream-ingest/internal/schemaready/**' \
  'services/jetstream-ingest/go.mod' \
  'services/jetstream-ingest/go.sum' \
  'database/migrations/**' \
  '.railway/**' \
  'package.json' \
  'bun.lock'
filter_changed go_packages \
  'services/*/Sources/*Core/**' \
  'packages/go/**' \
  'packages/swift/**' \
  'packages/read-state/**' \
  'packages/lexicons/**' \
  'packages/spec/**' \
  'scripts/go/**' \
  'database/migrations/**' \
  '.github/workflows/ci.yml'
