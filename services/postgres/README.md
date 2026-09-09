# Railway Postgres shutdown

This image extends the pinned Railway PostgreSQL 18 SSL template. It preserves the vendor initialization, backup, upgrade and volume-lock code and translates Railway's `SIGTERM` into `SIGINT` through the vendor `tini` process group. PostgreSQL then performs fast shutdown: disconnect sessions, roll back unfinished transactions and checkpoint before exiting. It does not use immediate shutdown or disable crash safety.

Railway sends TERM regardless of Docker's `STOPSIGNAL` and defaults to zero shutdown grace. Configure **`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=120`** on the Postgres service as well as selecting this image and `/railway/postgres.json`. The entrypoint intentionally waits for the shutdown checkpoint. The provider can still kill it after the grace period; monitor shutdown duration and interrupted-start logs. A forced stop or OOM can still discard unlogged tables and must retain recovery handling.

The existing deployment does not gain new signal handling merely because its replacement image is configured. Deploy first to an isolated restored volume and prove an actual Railway restart with unlogged sentinels. Before replacing an unadapted live deployment, arrange an explicit PostgreSQL fast stop during the controlled handoff and verify the clean-shutdown marker; never assume the old container now uses this entrypoint. Keep the original volume identity and database settings. Production PITR remains intentionally disabled, and daily snapshots remain independent.

Run `services/postgres/tests/shutdown.sh` for a network-isolated local test. It verifies two TERM restarts preserve 1,000 unlogged inbox sentinels, committed durable data, ALTER SYSTEM settings and archiving-off; an active transaction rolls back. It also verifies an unrequested clean database exit remains a failed container exit, retaining automatic recovery. This fixture is not a full-volume timing or Railway rollout proof.

Upgrades of the pinned vendor image require repeating the tests and reviewing its entrypoint/CMD and shutdown implementation. Do not remove the vendor wrapper or reparent its background helpers onto PostgreSQL.

Reference: [Railway deployment signals and shutdown grace](https://docs.railway.com/deployments/reference).
