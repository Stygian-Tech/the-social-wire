#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
name="tsw92-shutdown-${RANDOM}-$$"
image=${POSTGRES_SHUTDOWN_TEST_IMAGE:-tsw92-postgres-shutdown:test}
cleanup() { docker rm -fv "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cd "$root"
docker build -q -f services/postgres/Dockerfile -t "$image" . >/dev/null
# Local trust only; no published ports, credentials or external network.
docker run -d --name "$name" --network none --memory 1g \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e PGDATA=/var/lib/postgresql/data/pgdata \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres "$image" >/dev/null
ready() {
  for _ in $(seq 1 90); do
    if docker exec "$name" pg_isready -h 127.0.0.1 -U postgres -q; then return; fi
    sleep 1
  done
  docker logs "$name"; return 1
}
ready
sql() { docker exec "$name" psql -X -At -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"; }
sql 'CREATE UNLOGGED TABLE inbox_sentinel(id integer PRIMARY KEY); INSERT INTO inbox_sentinel SELECT generate_series(1,1000); CREATE TABLE durable_sentinel(id integer PRIMARY KEY); INSERT INTO durable_sentinel VALUES(1);' >/dev/null
sql "ALTER SYSTEM SET checkpoint_timeout='15min'" >/dev/null
# A live long transaction must be cancelled by fast shutdown, not hold smart shutdown open.
docker exec -d "$name" psql -X -U postgres -d postgres -c 'BEGIN; INSERT INTO durable_sentinel VALUES(2); SELECT pg_sleep(120); COMMIT;'
for _ in $(seq 1 30); do
  if [[ $(sql "SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'") == 1 ]]; then break; fi
  sleep 0.1
done
[[ $(sql "SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'") == 1 ]]
for cycle in 1 2; do
  docker stop --signal TERM --timeout 60 "$name" >/dev/null
  [[ $(docker inspect "$name" --format '{{.State.ExitCode}}') == 0 ]]
  docker start "$name" >/dev/null
  ready
  [[ $(sql 'SELECT count(*) FROM inbox_sentinel') == 1000 ]]
  [[ $(sql 'SELECT array_agg(id ORDER BY id) FROM durable_sentinel') == '{1}' ]]
  [[ $(sql 'SHOW checkpoint_timeout') == '15min' ]]
  [[ $(sql 'SHOW archive_mode') == 'off' ]]
done
# Also preserve the vendor behavior of failing on an unrequested clean exit.
# The container may exit before the exec session returns; assert its exit below.
docker exec -u postgres "$name" pg_ctl -D /var/lib/postgresql/data/pgdata -m fast -w stop >/dev/null || true
exit_code=$(docker wait "$name")
[[ "$exit_code" == 1 ]]
logs=$(docker logs "$name" 2>&1)
[[ "$logs" == *'received fast shutdown request'* ]]
[[ "$logs" != *'database system was interrupted'* ]]
printf 'PASS: two TERM restarts preserve 1,000 unlogged rows, durable commits and tuning; active transaction rolls back; unrequested stop exits 1.\n'
