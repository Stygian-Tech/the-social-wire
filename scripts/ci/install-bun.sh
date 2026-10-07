#!/usr/bin/env bash
set -euo pipefail

# A damaged cached archive may fail extraction. Retry only that failure once;
# frozen-lockfile and integrity failures must remain immediate failures.
install_log=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bun-install-log.XXXXXX")
trap 'rm -f "$install_log"' EXIT
set +e
bun install --frozen-lockfile 2>&1 | tee "$install_log"
install_status=${PIPESTATUS[0]}
set -e
if [ "$install_status" -eq 0 ]; then
  exit 0
fi
if ! grep -Eq '^error: Fail extracting tarball for "[^"]+"' "$install_log" || \
  grep -Eiq 'lockfile|integrity|checksum' "$install_log" || \
  grep '^error:' "$install_log" | grep -Ev '^error: Fail extracting tarball for "[^"]+"'; then
  exit "$install_status"
fi
retry_cache=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bun-install-cache.XXXXXX")
printf '%s\n' 'Retrying tarball extraction once with a fresh Bun cache.'
bun install --frozen-lockfile --cache-dir "$retry_cache"
