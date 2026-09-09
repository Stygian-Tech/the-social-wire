#!/usr/bin/env bash
# Railway always sends TERM; PostgreSQL needs INT for fast, clean shutdown.
# Keep the vendor wrapper and its foreground postmaster relationship intact.
set -u

child=''
stop_requested=0
request_stop() {
  stop_requested=1
  if [[ -n "$child" ]]; then
    kill -INT "$child" 2>/dev/null || true
  fi
}
trap request_stop TERM INT

# An asynchronous shell child inherits ignored INT. Reset that disposition
# before tini installs its handlers and starts the unchanged vendor wrapper.
/usr/bin/env --default-signal=INT,TERM /usr/bin/tini -s -g -- /usr/local/bin/wrapper.sh "$@" &
child=$!
if [[ "$stop_requested" == 1 ]]; then request_stop; fi

# A trap interrupts bash's wait before the child exits. Continue waiting so
# the platform's grace period belongs to the database's shutdown checkpoint.
while true; do
  wait "$child"
  result=$?
  if ! kill -0 "$child" 2>/dev/null; then exit "$result"; fi
done
