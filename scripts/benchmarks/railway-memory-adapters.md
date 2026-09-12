# Read-only Railway memory-trial adapters

`railway_memory_identity.py` and `railway_memory_probe.py` implement the existing runner's `identity` and `probe` contracts. They accept `{}` on stdin and load `TSW92_TRIAL_CONFIG`. They do not create environments, copy snapshots, set variables or memory limits, start services, reset counters, or restart PostgreSQL. No hosted trial has been run with them.

Both adapters require a new `tsw92-*` environment in The Social Wire project, separate `tsw92-*` database/runner/application services, an SFO database volume, one successful deployment and one running instance per inspected service. Actual canonical Development/Production environment IDs, Postgres volume/service IDs and core application service IDs are protected in code even if omitted from configuration. Keep the complete source inventory in `protected_source_ids` too. The retained restore service currently attached to Production cannot pass these checks.

Provider identity comes from live Railway GraphQL queries through `railway api`: environment/project, volume attachment and readiness, active deployments, private network and endpoint mappings. Queries omit service variables, commands, logs and opaque deployment metadata. The private hostname must match the provider's service-instance endpoint. The SSH destination uses that **service-instance ID**, as confirmed by `railway ssh config --dry-run`, rather than a deployment-instance ID. Remote `RAILWAY_DEPLOYMENT_ID` must match the freshly queried deployment, detecting a concurrent replacement.

Provision these tools and files before invoking either adapter:

- Railway CLI and OpenSSH at explicit absolute executable paths on the isolated runner; Python 3 for the adapters.
- An externally supplied, owner-only SSH identity file. OpenSSH host verification is strict, uses existing known hosts, and never edits SSH configuration or registers a key. Populate trusted host keys through the existing operator-managed process.
- An authenticated Railway CLI session in the runner's `HOME`, or an explicitly supplied owner-only token file. Choose `railway_token_kind: "project"` for a project token or `"account"` for an API token. The adapter passes this only in the CLI child's environment, never argv/stdout. It does not discover or extract credentials from other applications; normal service database/token environment variables are not forwarded to the CLI.
- On the isolated database image: Python 3, GNU `timeout`, `psql`, and the reviewed `postgres_memory_trial.py` and `postgres_replay.py` files. The adapter copies nothing. Supply matching hashes for both files and the existing verified full-snapshot attestation on the mounted volume.
- The database service's explicitly named database URL environment variable, used by the existing probe inside that service. Its value stays on the service; no URL is returned to the runner.

Add the following `provider` object to the reviewed round configuration. Values below are placeholders, not runnable evidence:

```json
{
  "provider": {
    "railway_binary": "/usr/local/bin/railway",
    "ssh_binary": "/usr/bin/ssh",
    "ssh_identity_file": "/run/secrets/trial-ssh-key",
    "railway_token_file": "/run/secrets/trial-railway-token",
    "railway_token_kind": "project",
    "remote_probe_directory": "/benchmark",
    "module_sha256": "<SHA-256 of railway_memory_adapters.py>",
    "probe_sha256": {
      "postgres_memory_trial.py": "<SHA-256>",
      "postgres_replay.py": "<SHA-256>"
    }
  }
}
```

Omit both token fields only when the runner has its own already-authenticated CLI session. Pin the two executable adapters in `runner.adapters` and its binary manifest as usual; retain the provider module and remote probe hashes in that reviewed manifest as well. The executing runner must expose matching Railway project, environment, service and deployment IDs.

`identity` independently checks every configured read origin, then verifies the restored snapshot and live database identity through the remote probe before returning the runner's exact identity response shape. `probe` refreshes database/runner provider identity and returns the existing cgroup/database sample unchanged. Both execute the existing read-only SQL probe inside the database cgroup. Counter epochs, observed times and missing data are preserved, not synthesized. The probe returns requested `memory_limit_bytes`, raw `memory_max`, and `page_size_bytes` measured inside the database container; Linux page flooring is checked by the shared probe rule, never inferred from the runner host. Update both pinned probe hashes after this change.

The subprocess transport caps stdin at 64 KiB, stdout at 2 MiB, CLI/SSH commands at 12 seconds, and the remote read-only process group at ten seconds plus one second of forced termination grace. The runner's existing shorter per-adapter deadline still applies; adapter latency that exceeds the configured sampling budget fails the trial. Cancellation or timeout retires only owned local process groups; an independent remote `timeout` bounds reads even if SSH disconnects. Remote Python bytecode writes are disabled. Errors do not echo provider output, SQL, credentials or raw exceptions.

## Container replacement remains unsupported

The Railway public schema inspected on September 12 exposes deployment-instance `id` and `status`, not a termination reason or OOM flag. `Deployment.diagnosis` is an untyped scalar and was null on the inspected deployment. Restart success, a scheduled timestamp or absence of a diagnosis cannot prove `oom_killed: false` for a previous container epoch.

The identity/probe adapters remain read-only. A separate [trial-only clean process restart](trial-postgres-process-restart.md) now supplies the explicit `retained_container_kernel` path: the same container and kernel OOM counters survive while the owned PostgreSQL subtree restarts. Its reviewed supervisor, additional pinned modules and independent nonce record are mandatory. It cannot substitute for a missing provider receipt after container loss or prove crash/discovery recovery. The full runner still requires every workload, restore, lifecycle and acceptance gate; do not fill missing evidence with test fixtures.

Validation uses local fixtures and owned subprocesses only:

```sh
python3 -W error::ResourceWarning -m unittest discover -s scripts/benchmarks/tests
```
