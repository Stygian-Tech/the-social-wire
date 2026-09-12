# Isolated memory-trial supervisor

`postgres_memory_trial_runner.py` supplies the missing owned-process supervisor and bounded authenticated GET driver around the existing `postgres_memory_trial.py` evidence gates. It has **not been run against Railway**. The repository does not contain a reviewed representative trace, an isolated OAuth session, a source inventory, or the operator's concrete remote adapters; consequently no memory capacity trial has been completed by adding it.

Run only in a **separate isolated Railway runner**, co-located with the isolated database/application environment. The database probe must still execute inside the database service's cgroup. The runner verifies its actual Railway environment variables, the original database service/volume/snapshot identity contract, private read origins and a provider-derived identity adapter response before starting load. Its adapters must be reviewed executable files with pinned SHA-256 digests; they receive configuration through `TSW92_TRIAL_CONFIG`. A separate reviewed binary manifest must include their exact `adapters` hash map and the deployed application hashes/configuration. Scripts cannot prove that an operator-provided adapter or a trace is representative merely from these labels.

Use the round config's explicit `memory_limit_bytes` unchanged in the runner and database probe: `13000000000`, `12000000000`, `11000000000`, then `10000000000` for Railway's decimal 13, 12, 11 and 10 GB trials (`16000000000` remains the baseline). Preflight and every observed sample must match that integer exactly; neither the runner nor probe translates GB to GiB or accepts the retired `memory_gib` field. The final summary retains the exact byte cap.

Extend the existing round config with:

- `runner.project_id`, `environment_id`, `service_id`: exact isolated runner IDs. It must share the target environment/project and cannot be the database or a protected source service.
- `runner.concurrency`: 1–32 outstanding logical reads; `request_timeout_seconds`: positive and no longer than `sample_seconds`. Failure to sustain the offered rate fails the trial; requests are not quietly buffered to lower effective load.
- `runner.token_file`: existing owner-only file (0600), supplied to the signer as `TSW92_TOKEN_FILE`. No token values belong in a trace/config/command argument.
- `runner.binary_manifest_file`: path whose SHA-256 matches the existing `binary_manifest_sha256`.
- `runner.minimum_replay_per_minute`, `minimum_rankings_per_minute`: positive successful-throughput floors selected from the reviewed workload. Progress is measured as actual applied records and whole committed generations. Set `runner.throughput_window_seconds` (60–600) to cover the existing ranking cadence; for example, a ten-minute window can assess a fractional per-minute ranking floor without demanding a new generation every minute. Choose the floor from measured baseline throughput, never arbitrary example rates.
- `runner.adapters`: exactly `identity`, `probe`, `signer`, `replay`, `ranking`, `restart`, each `{ "path": "/absolute/reviewed/executable", "sha256": "<digest>" }`. There is no shell command interpolation or inherited database credential environment.
- `read_targets`: named `{ "origin": "http://tsw92-<isolated>.railway.internal:<port>", "service_id": "<isolated service UUID>" }` objects. Public URLs, proxies and redirects are forbidden. The identity adapter must independently verify these names map to the specified service in the isolated environment.

Adapters have narrow interfaces:

| Adapter | Contract |
|---|---|
| `identity` | Read-only provider lookup; stdin `{}`; output exactly `{target, runner:{project_id,environment_id,service_id}, read_targets, snapshot_sha256}` after verifying the actual deployment/service/volume/private-origin mappings and reviewed restore attestation. Do not echo the config as a substitute for provider verification. |
| `probe` | Execute the existing `sample` command inside the named isolated database service and return its JSON, with no fabricated load object. Preflight probes run before workers. |
| `signer` | Stdin `{method:"GET",url,nonce?}`; output OAuth `Authorization`, `DPoP`, optional `Accept` headers using the supplied isolated viewer's session. Validate the destination against the config before releasing credentials; use the existing application OAuth/DPoP implementation. The runner supports one genuine 400/401 DPoP nonce retry, never substitutes bearer auth or bypasses Gateway verification. |
| `replay` | Supervised long-lived intake of a reviewed fixed archive range through existing replay facilities into the isolated target. Disable live upstream collection and restored source-worker credentials. Emit only JSONL `{"completed":<cumulative successfully applied records>}`. Mere archive submissions are not successful throughput. |
| `ranking` | Supervised actual ranking workload using the restored full corpus and reviewed languages/settings. Emit JSONL `{"completed":<cumulative committed complete generations>}`. Do not replace publication work with a synthetic insert loop. |
| `restart` | Restart **only** the explicitly named isolated database service, wait for queryability, and obtain the independent provider termination/OOM receipt. Stdin `{previous_container_epoch}`; return the existing `restart_receipt` shape. Never generate an OOM receipt solely from the schedule. |

The replay/ranking adapters must own their descendant processes and stop intake on SIGTERM; do not detach remote services that cannot be stopped by their owning adapter. The supervisor kills only process groups it created, with TERM then KILL, on any error, timeout, failed resource gate, worker exit or signal. It retains the database and evidence; it does not delete queues, restore volumes, tune memory, or change Production. If remote jobs cannot be stopped this way, the adapter is unsuitable and the trial must not launch.

Supply the trace file separately; its exact bytes must match `workload_sha256`:

```json
{
  "dataset": "reviewed_authenticated_trace",
  "source_evidence": "<reviewed private trace/inventory reference>",
  "rates": {"mixed": 10, "burst": 20, "recovery": 10},
  "requests": [
    {"id": "sidebar-viewer-a", "category": "sidebar", "target": "gateway", "path": "/v1/publications/sidebar"}
  ]
}
```

The example is intentionally incomplete and **will fail** until actual requests cover `sidebar`, `bootstrap`, `pagination`, `detail`, and `language_feed`. The example rates are illustrative, not recommended capacity levels. Replay segment hashes/bounds, corpus age treatment, per-request viewer identity and application binary/configuration evidence belong in the reviewed manifest/trace and signer adapter; keep them identical between memory rounds. Requests are GET-only: any required authenticated mutation/action replay needs a separately reviewed adapter before claiming that the full product workload was represented.

The driver permits only these verified GET contracts, with query strings preserved for the signer:

| Category | Allowed routes |
|---|---|
| `sidebar` | `/v1/publications/sidebar`, `/xrpc/app.thesocialwire.publication.getSidebar` |
| `bootstrap` | `/v1/appview/bootstrap-stream` |
| `pagination` | `/v1/appview/entries`, `/v1/appview/feed`, `/xrpc/app.thesocialwire.appview.listEntries`, `/xrpc/app.thesocialwire.appview.getFeed`, `/xrpc/app.thesocialwire.discovery.getWire` |
| `detail` | `/v1/appview/entry`, `/xrpc/app.thesocialwire.appview.getEntry` |
| `language_feed` | `/xrpc/app.thesocialwire.discovery.getWire` |

Unknown XRPC methods, mutations, category/route mismatches, redirects and non-private origins fail closed before load. These aliases are verified against Gateway `AppViewProxyRoutes.swift`, AppView entry models, the bootstrap stream contract and the `discovery.getWire` lexicon.

A successful response must finish within the existing time/8 MiB bounds and match its JSON or NDJSON contract. Error objects, malformed/truncated JSON, incorrect detail identity, malformed entries, and Wire source/degradation mismatches fail. Wire reads must return nonempty generation-bound items and match an explicitly requested language. By default each Wire trace item requires `expected_source: "ranked"` and `expected_degraded: false`. A documented degraded baseline may instead pin both explicit values and a nonempty `baseline_evidence` reference on that item; each response must match them exactly, so a new source/degradation change still fails. Those trace fields are hashed with the workload and cannot establish baseline validity without independent source evidence review. Bootstrap streams require a sidebar projection, one terminal `done` event with its observation timestamp, no warning/error/unavailable events, and entries for any selected publication. Empty AppView pages and a complete bootstrap for a viewer without a selection remain valid contract responses. Payloads are checked only in memory and never written to evidence. These checks do not establish trace representativeness, pagination traversal, viewer isolation, generation freshness per language, or discovery rebuild acceptance; those remain separate trial gates.

After provisioning, restoring and reviewing all inputs, an operator can invoke:

```sh
python3 /benchmark/postgres_memory_trial_runner.py /benchmark/memory-16.json /benchmark/reviewed-trace.json /benchmark/evidence/memory-16
```

The output directory must not already exist. Samples, per-request timing/category evidence, final summary or failure reason are owner-only files. Successful logical requests include their OAuth handshake duration; HTTP errors, rate limits, incomplete responses and responses above 8 MiB fail. Raw credentials, request URLs and response bodies are never logged. The seeded request selection and phase rates are identical inputs across rounds. The existing validator still requires at least one measured hour excluding the controlled restart, five minutes of burst, ten minutes of recovered load, unchanged epochs apart from the approved restart, zero final actionable queue, and passing OOM/latency/headroom/archive/connection gates. Worker completion deltas are also checked over the configured throughput window and converted to per-minute rates. A missing signer, trace, adapter, provider receipt or representativeness review remains an unfulfilled trial gate.

Tests use disposable **local** subprocesses, temporary credential placeholders and fabricated telemetry; they make no HTTP requests and provide no memory-capacity evidence:

```sh
python3 -m unittest discover -s scripts/benchmarks/tests
```
