#!/usr/bin/env bash
set -euo pipefail
fixture_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$fixture_dir/../../../.." && pwd)
# Node 22 reference image pinned to the tested multi-platform manifest.
image='node:22-bookworm@sha256:8a34c4ab3ea2c5cd194f07e317b2a8f09461d3c8b05c4e34c8ccd56d56024c4d'
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/tsw-reference-pds.XXXXXX")
output_dir=${1:-"$run_dir/evidence"}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
cleanup() {
  if [[ "$output_dir" == "$run_dir/"* ]]; then
    rm -rf "$run_dir/node_modules" "$run_dir/source"
  else
    rm -rf "$run_dir"
  fi
}
trap cleanup EXIT
cp "$fixture_dir/"{conformance.ts,package.json,package-lock.json,tsconfig.json} "$run_dir/"
mkdir -p "$run_dir/source"
cp -R "$repo_dir/packages/read-state/src" "$run_dir/source/core"
# Source snapshots are used unchanged. tsconfig maps the browser Buffer import for Node.
cp "$repo_dir/apps/web/src/lib/pdsReadStateProof.ts" "$run_dir/source/proof.ts"
(cd "$run_dir" && find source -type f -exec shasum -a 256 {} \;) > "$output_dir/source-sha256.txt"
# Dependency installation is the sole networked phase. No PDS process runs in this phase.
docker run --rm -v "$run_dir:/fixture" -w /fixture "$image" npm ci --no-audit --no-fund > "$output_dir/install.log" 2>&1
# No network, published ports, SMTP, host identity, production URL or user credentials.
docker run --rm --init --network none --cap-drop ALL --security-opt no-new-privileges \
  --memory 2g --pids-limit 256 -e TSW_REFERENCE_PDS_ISOLATED=1 -e LOG_ENABLED=false \
  -v "$run_dir:/fixture" -w /fixture "$image" npm test > "$output_dir/run.log" 2>&1
cp "$run_dir/results.json" "$output_dir/results.json"
cat "$output_dir/run.log"
echo "Evidence: $output_dir"
