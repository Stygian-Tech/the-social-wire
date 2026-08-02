#!/usr/bin/env bash
# Safely replace Social Wire Fly Machines with equivalent Machines in IAH.
# Dry-run is the default. Destruction requires both --apply and --confirm-destroy-old.
set -euo pipefail

TARGET_REGION="iah"
APPLY=0
CONFIRM_DESTROY=0
declare -a REQUESTED_APPS=()
declare -a MIGRATION_ORDER=(
  the-social-wire-dev-tap
  the-social-wire-dev-appview-worker
  the-social-wire-dev-operations
  the-social-wire-dev-appview
  the-social-wire-dev-gateway
  the-social-wire-prod-tap
  the-social-wire-prod-appview-worker
  the-social-wire-prod-operations
  the-social-wire-prod-appview
  the-social-wire-prod-gateway
)

usage() {
  cat <<'USAGE'
Usage: scripts/fly-migrate-region.sh [--apply --confirm-destroy-old] [APP ...]

With no APP arguments, inspects or migrates all ten apps in dependency order.
The default is a read-only dry-run. Apply mode clones/replaces only known apps,
refuses apps with volumes, verifies replacements, and destroys old Machines only
after --confirm-destroy-old is also supplied.
USAGE
}

is_known_app() {
  local candidate="$1"
  local known
  for known in "${MIGRATION_ORDER[@]}"; do
    [[ "$candidate" == "$known" ]] && return 0
  done
  return 1
}

is_singleton_consumer() {
  [[ "$1" == *-tap || "$1" == *-appview-worker ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --confirm-destroy-old) CONFIRM_DESTROY=1 ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if ! is_known_app "$1"; then
        echo "Refusing unknown Fly app: $1" >&2
        exit 2
      fi
      REQUESTED_APPS+=("$1")
      ;;
  esac
  shift
done

if [[ "$APPLY" -eq 1 && "$CONFIRM_DESTROY" -ne 1 ]]; then
  echo "Apply mode also requires --confirm-destroy-old." >&2
  exit 2
fi

for dependency in flyctl jq curl; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Required command not found: $dependency" >&2
    exit 1
  fi
done

if [[ "${#REQUESTED_APPS[@]}" -eq 0 ]]; then
  REQUESTED_APPS=("${MIGRATION_ORDER[@]}")
fi

machine_process_group() {
  jq -r '.config.metadata.fly_process_group // .config.metadata["fly_process_group"] // "app"'
}

assert_no_volumes() {
  local app="$1"
  local volumes
  volumes="$(flyctl volumes list --app "$app" --json)"
  if [[ "$(jq 'length' <<<"$volumes")" -ne 0 ]]; then
    echo "Refusing $app: an unexpected Fly Volume is attached." >&2
    jq -r '.[] | "  volume=\(.id) region=\(.region) state=\(.state // "unknown")"' <<<"$volumes" >&2
    exit 1
  fi
}

ensure_started() {
  local app="$1" machine_id="$2"
  local attempt state
  state="$(
    flyctl machine list --app "$app" --json |
      jq -r --arg machine "$machine_id" '.[] | select(.id == $machine) | .state'
  )"
  if [[ "$state" != "started" ]]; then
    flyctl machine start "$machine_id" --app "$app"
  fi
  for attempt in $(seq 1 36); do
    state="$(
      flyctl machine list --app "$app" --json |
        jq -r --arg machine "$machine_id" '.[] | select(.id == $machine) | .state'
    )"
    [[ "$state" == "started" ]] && return 0
    sleep 5
  done
  echo "Replacement $machine_id for $app did not reach started state." >&2
  return 1
}

clone_into_target() {
  local app="$1" old_id="$2"
  local before_ids new_machines attempt
  before_ids="$(flyctl machine list --app "$app" --json | jq '[.[].id]')"
  flyctl machine clone "$old_id" --app "$app" --region "$TARGET_REGION" --detach >/dev/null
  for attempt in $(seq 1 20); do
    new_machines="$(
      flyctl machine list --app "$app" --json |
        jq --argjson before "$before_ids" --arg region "$TARGET_REGION" '
          [.[] as $machine
            | $machine
            | select(($before | index($machine.id)) == null and $machine.region == $region)]
        '
    )"
    if [[ "$(jq 'length' <<<"$new_machines")" -eq 1 ]]; then
      jq -c '.[0]' <<<"$new_machines"
      return 0
    fi
    if [[ "$(jq 'length' <<<"$new_machines")" -gt 1 ]]; then
      echo "Refusing $app: multiple replacement Machines appeared during clone." >&2
      return 1
    fi
    sleep 2
  done
  echo "Could not identify the IAH replacement cloned from $old_id in $app." >&2
  return 1
}

verify_http_service() {
  local app="$1" machine_id="$2" stage="$3"
  ensure_started "$app" "$machine_id"
  flyctl checks list --app "$app" --json | jq -e '
    length > 0 and all(.[]; ((.status // "") | ascii_downcase) == "passing")
  ' >/dev/null
  curl --fail --silent --show-error --max-time 10 "https://${app}.fly.dev/readyz" >/dev/null
  if [[ -z "${FLY_MIGRATION_HTTP_VERIFY_COMMAND:-}" ]]; then
    echo "Set FLY_MIGRATION_HTTP_VERIFY_COMMAND to an executable that verifies real traffic and internal service calls." >&2
    return 1
  fi
  "$FLY_MIGRATION_HTTP_VERIFY_COMMAND" "$app" "$machine_id" "$stage"
}

verify_singleton_evidence() {
  local app="$1" machine_id="$2" stage="$3"
  if [[ -z "${FLY_MIGRATION_SINGLETON_VERIFY_COMMAND:-}" ]]; then
    echo "Set FLY_MIGRATION_SINGLETON_VERIFY_COMMAND to record checkpoint, heartbeat, backlog, and active-lease evidence." >&2
    return 1
  fi
  "$FLY_MIGRATION_SINGLETON_VERIFY_COMMAND" "$app" "$machine_id" "$stage"
}

migrate_machine() {
  local app="$1" old_machine_json="$2"
  local old_id old_region old_state process_group replacement_json replacement_id
  old_id="$(jq -r '.id' <<<"$old_machine_json")"
  old_region="$(jq -r '.region' <<<"$old_machine_json")"
  old_state="$(jq -r '.state' <<<"$old_machine_json")"
  process_group="$(machine_process_group <<<"$old_machine_json")"

  [[ "$old_region" == "$TARGET_REGION" ]] && return 0
  echo "Migrating app=$app machine=$old_id process=$process_group state=$old_state region=$old_region -> $TARGET_REGION"

  if [[ "$APPLY" -ne 1 ]]; then
    if is_singleton_consumer "$app"; then
      echo "  DRY-RUN: record checkpoint/heartbeat/backlog; stop $old_id; clone it into $TARGET_REGION; verify progression and lease; destroy $old_id"
    else
      echo "  DRY-RUN: clone $old_id into $TARGET_REGION; verify checks and /readyz; stop $old_id; recheck; destroy $old_id"
    fi
    return 0
  fi

  if is_singleton_consumer "$app"; then
    verify_singleton_evidence "$app" "$old_id" before_old_stop
    flyctl machine stop "$old_id" --app "$app"
    replacement_json="$(clone_into_target "$app" "$old_id")"
    replacement_id="$(jq -r '.id' <<<"$replacement_json")"
    ensure_started "$app" "$replacement_id"
    verify_singleton_evidence "$app" "$replacement_id" after_replacement_start
  else
    replacement_json="$(clone_into_target "$app" "$old_id")"
    replacement_id="$(jq -r '.id' <<<"$replacement_json")"
    verify_http_service "$app" "$replacement_id" before_old_stop
    flyctl machine stop "$old_id" --app "$app"
    verify_http_service "$app" "$replacement_id" after_old_stop
  fi

  if [[ "$old_state" != "started" ]]; then
    flyctl machine stop "$replacement_id" --app "$app"
  fi

  flyctl machine destroy "$old_id" --app "$app" --force
  echo "Verified replacement $replacement_id; destroyed predecessor $old_id."
}

for app in "${REQUESTED_APPS[@]}"; do
  echo "==> $app"
  assert_no_volumes "$app"
  machines="$(flyctl machine list --app "$app" --json)"
  if [[ "$(jq 'length' <<<"$machines")" -eq 0 ]]; then
    echo "Refusing $app: no Machines found." >&2
    exit 1
  fi
  jq -r '.[] | "  machine=\(.id) process=\(.config.metadata.fly_process_group // "app") state=\(.state) region=\(.region)"' <<<"$machines"
  while IFS= read -r machine; do
    migrate_machine "$app" "$machine"
  done < <(jq -c '.[]' <<<"$machines")

  if [[ "$APPLY" -eq 1 ]]; then
    final_machines="$(flyctl machine list --app "$app" --json)"
    if ! jq -e --arg region "$TARGET_REGION" 'length > 0 and all(.[]; .region == $region)' <<<"$final_machines" >/dev/null; then
      echo "Region assertion failed for $app." >&2
      jq -r '.[] | "  machine=\(.id) state=\(.state) region=\(.region)"' <<<"$final_machines" >&2
      exit 1
    fi
  fi
done

if [[ "$APPLY" -eq 1 ]]; then
  echo "All selected Fly Machines are in $TARGET_REGION."
else
  echo "Dry-run complete. No Machines were changed."
fi
