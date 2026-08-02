#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_REGION="iah"
EXPECTED_COUNT=10

mapfile -t configs < <(find "$ROOT/services" -type f -name 'fly*.toml' | sort)

if [[ "${#configs[@]}" -ne "$EXPECTED_COUNT" ]]; then
  echo "Expected $EXPECTED_COUNT Fly configurations, found ${#configs[@]}." >&2
  printf '  %s\n' "${configs[@]#"$ROOT/"}" >&2
  exit 1
fi

failed=0
for config in "${configs[@]}"; do
  region="$(
    sed -nE "s/^[[:space:]]*primary_region[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*$/\1/p" "$config"
  )"
  if [[ "$region" != "$EXPECTED_REGION" ]]; then
    echo "${config#"$ROOT/"}: primary_region must be exactly '$EXPECTED_REGION' (found '${region:-missing}')." >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Verified all $EXPECTED_COUNT Fly configurations use primary_region = '$EXPECTED_REGION'."
