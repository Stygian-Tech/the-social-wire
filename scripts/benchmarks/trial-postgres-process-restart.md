# Clean PostgreSQL process restart in an isolated memory trial

This path exercises a **clean process restart**, with the database container and its kernel OOM counters retained. It does not exercise container replacement, crash recovery, snapshot restoration or discovery rebuild, and its local fixtures are not memory-capacity evidence. Production images, entrypoints, settings and services are unchanged.

Build the separate trial image from the repository root:

```sh
docker build -f scripts/benchmarks/fixtures/postgres-restart/Dockerfile -t tsw114-postgres-process-restart:test .
TSW_RESTART_TEST_IMAGE=tsw114-postgres-process-restart:test python3 -W error::ResourceWarning -m unittest discover -s scripts/benchmarks/tests -p test_trial_postgres_restart.py
```

The test creates and removes only its uniquely named local container, uses no network, and supplies explicitly synthetic identities and snapshot attestation. That fixture proves lifecycle mechanics only. Hosted trials still require independent provider identity, a verified full restore and every existing load/queue/latency/recovery gate.

## Supervision and ownership

The trial image runs `trial_postgres_supervisor.py` as PID1. A guardian subreaper owns the existing `railway-entrypoint.sh → tini → vendor wrapper → PostgreSQL` subtree. The vendor wrapper remains unchanged, retaining SSL, volume locks, initialization, backups and its direct foreground postmaster relationship. The outer supervisor receives only one explicit request over an owner-only Unix socket. It signals the existing entrypoint for fast, clean shutdown, waits for a zero exit, retires the guardian's remaining descendants, then launches exactly one replacement subtree.

Some vendor helpers detach into separate process groups and ignore TERM/INT. The guardian remains alive while adopting those descendants; it uses Linux pidfds and rechecked ancestry to terminate only its own subtree. After a short graceful retirement it kills any remaining owned helper and reaps it. SSH/probe processes and workload services are outside the guardian. Workload intake, ranking and query workers are never paused or respawned by this adapter.

An unexpected child exit, nonzero requested exit, changed identity/cap, OOM counter, ambiguous shutdown or readiness timeout fails the trial. There is no automatic database restart loop. A failed shutdown cannot start a second postmaster. A disconnected control client does not undo or repeat an authorized restart: the supervisor completes its bounded operation and writes its receipt privately, while the runner reports failure if it did not receive verified evidence. Never retry under a fresh nonce to make that round pass. A duplicate request is rejected without touching the replacement database.

## Provisioned contract

Use a new protected-identity-checked `tsw92-*` environment/service/volume. Provision the ordinary reviewed trial configuration at the database's `TSW92_TRIAL_CONFIG` as an owner-only regular file. Its target IDs must equal the actual Railway environment variables; the mount must be `/var/lib/postgresql/data`, with `PGDATA` beneath it. The reviewed full-snapshot attestation must already be on that volume. The configured trial database must be locally queryable by the `postgres` service user over the Unix socket.

Add the following configuration, replacing placeholders with actual reviewed file hashes:

```json
{
  "restart": {
    "mode": "postgres_process",
    "supervisor_sha256": "<sha256 of trial_postgres_supervisor.py>",
    "evidence_sha256": "<sha256 of trial_restart_evidence.py>"
  }
}
```

Add `trial_restart_evidence.py` and `trial_postgres_supervisor.py` to `provider.probe_sha256`, alongside the existing two probe modules. Pin `railway_memory_restart.py` as the runner's `restart` adapter, and update the binary manifest plus existing provider/probe hashes. Keep the reviewed evidence module beside both the runner adapter and the remote probe. Hashes are required to match the deployed trial image; updating source alone never validates an old image.

The runner creates a fresh request nonce and sends its immediately preceding container epoch and postmaster start time. The adapter independently refreshes provider identity and probes the target before contacting the supervisor. It refreshes provider identity and probes again after receiving the receipt. The supervisor records raw kernel identity, OOM counters, exact cap/page size, postmaster PID/start ticks, database/cluster identity and restore attestation before and after the actual stop/start.

`Round` has a separate `retained_container_kernel` receipt branch. It cross-checks both receipt observations against adjacent samples and the expected nonce, requiring unchanged provider instance/service instance, deployment, volume, cgroup device/inode, host boot ID, PID namespace, PID1 start ticks, supervisor hash, cap and restore epoch. OOM/kill counters must be present, unchanged and zero, including `oom_group_kill` when exposed. The postmaster start time and process identity must change and match the adjacent observations. Ordered timestamps, a clean owned-child exit and complete subtree retirement are mandatory.

Container replacement cannot use this receipt type. If the retained identity changes, this trial stops; independent provider termination/OOM evidence remains necessary for any separate container-replacement trial. The restart gap remains excluded from measured workload duration and existing grace limits remain in force. Passing these mechanics does not waive representative replay, one-hour observation, complete discovery rebuild or Production promotion checks.

For independent replay of saved evidence, retain the runner's owner-only `restart-request.json`, which is flushed and fsynced **before** the mutation. Pass it separately with `postgres_memory_trial.py validate CONFIG --samples samples.jsonl --restart-request restart-request.json`; `watch` accepts the same path and reads it when the restart observation arrives. The expected nonce comes from that independent request, never from the returned receipt. Missing, mismatched or late request evidence fails validation.
