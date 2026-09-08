#!/usr/bin/env python3
"""Supervise an explicitly isolated memory trial. Requires reviewed trace and adapters."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import queue
import random
import select
import signal
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SPEC = importlib.util.spec_from_file_location("memory_trial", Path(__file__).with_name("postgres_memory_trial.py"))
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)
Error = trial.Error
CATEGORIES = {"sidebar", "bootstrap", "pagination", "detail", "language_feed"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def checked_adapter(value):
    """Adapters are reviewed executable files, not shell strings or inline commands."""
    path = Path(value["path"])
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise Error("Adapter must be an absolute executable file")
    if digest(path) != value["sha256"]:
        raise Error("Adapter differs from reviewed binary manifest")
    return str(path)


def validate_inputs(config, trace_path, environment=os.environ):
    trial.validate_config(config)
    runner = config["runner"]
    if config["restart_at_seconds"] < 1500:
        raise Error("Restart must follow the complete five-minute burst")
    if any(environment.get(trial.IDENTITIES[key]) != runner[key] for key in ("project_id", "environment_id", "service_id")):
        raise Error("Run only inside the explicitly identified isolated Railway runner")
    if runner["project_id"] != config["target"]["project_id"] or runner["environment_id"] != config["target"]["environment_id"]:
        raise Error("Runner and database must share the isolated environment")
    if runner["service_id"] == config["target"]["service_id"] or runner["service_id"] in config["protected_source_ids"]:
        raise Error("Load must run separately from the database and protected services")
    if Path(trace_path).stat().st_size > 16 * 1024 * 1024:
        raise Error("Reviewed workload trace exceeds 16 MiB")
    if digest(trace_path) != config["workload_sha256"]:
        raise Error("Trace hash differs from the reviewed workload")
    trace = json.loads(Path(trace_path).read_text())
    if trace["dataset"] != "reviewed_authenticated_trace" or not trace["source_evidence"]:
        raise Error("A reviewed workload trace and source evidence reference are required")
    if set(trace["rates"]) != {"mixed", "burst", "recovery"}:
        raise Error("Explicit offered rates are required for every phase")
    for rate in trace["rates"].values():
        if isinstance(rate, bool) or not math.isfinite(rate) or not 1 <= rate <= 100:
            raise Error("Offered rates must be 1–100 requests per second")
    if trace["rates"]["burst"] <= trace["rates"]["mixed"]:
        raise Error("Burst must offer more load than the baseline")
    if not 5 <= len(trace["requests"]) <= 10000 or {item["category"] for item in trace["requests"]} != CATEGORIES:
        raise Error("Trace must cover sidebar, bootstrap, pagination, detail and language feeds")
    if not 1 <= runner["concurrency"] <= 32 or not 0 < runner["request_timeout_seconds"] <= config["sample_seconds"]:
        raise Error("Bound concurrency and request timeout to the sample interval")
    for item in trace["requests"]:
        origin = config["read_targets"][item["target"]]
        parsed = urllib.parse.urlsplit(origin["origin"])
        if (parsed.scheme != "http" or not parsed.hostname or not trial.re.fullmatch(r"tsw92-[a-z0-9-]+\.railway\.internal", parsed.hostname)
                or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
            raise Error("Read targets must be explicit isolated private Railway origins")
        if origin["service_id"] in config["protected_source_ids"] or origin["service_id"] == config["target"]["service_id"]:
            raise Error("Read target cannot be a protected service or the database")
        if not item["path"].startswith("/xrpc/") or urllib.parse.urlsplit(item["path"]).netloc or "#" in item["path"]:
            raise Error("Only relative XRPC GET paths are accepted")
        if not isinstance(item["id"], str) or not item["id"] or len(item["id"]) > 128:
            raise Error("Trace request IDs must be short nonsecret identifiers")
    token = Path(runner["token_file"])
    if token.is_symlink() or not token.is_file() or stat.S_IMODE(token.stat().st_mode) & 0o077:
        raise Error("Token file must be private to its owner and cannot be a symlink")
    for adapter in runner["adapters"].values():
        checked_adapter(adapter)
    required = {"identity", "probe", "signer", "replay", "ranking", "restart"}
    if set(runner["adapters"]) != required:
        raise Error("Explicit identity, probe, signer, replay, ranking and restart adapters required")
    # The operator reviews hashes of every adapter as part of the binary manifest.
    manifest = Path(runner["binary_manifest_file"])
    if digest(manifest) != config["binary_manifest_sha256"]:
        raise Error("Binary manifest hash mismatch")
    binary = json.loads(manifest.read_text())
    if binary["adapters"] != {name: spec["sha256"] for name, spec in runner["adapters"].items()}:
        raise Error("Adapter hashes are absent from the reviewed binary manifest")
    if not 60 <= runner["throughput_window_seconds"] <= 600:
        raise Error("Use a 60–600 second throughput window appropriate to ranking cadence")
    if not 0 < runner["minimum_replay_per_minute"] or not 0 < runner["minimum_rankings_per_minute"]:
        raise Error("Measured minimum ingestion and ranking throughput are required")
    return trace


class Children:
    """Only terminate process groups this runner itself created; never kill by name."""
    def __init__(self):
        self.processes = []
        self.lock = threading.Lock()
        self.closed = False

    def start(self, argv, **kwargs):
        with self.lock:
            if self.closed:
                raise Error("Trial is stopping; no more children may start")
            process = subprocess.Popen(argv, start_new_session=True, **kwargs)
            self.processes.append(process)
        return process

    def release(self, process):
        with self.lock:
            self.processes.remove(process)

    def stop(self):
        with self.lock:
            self.closed = True
            processes = list(self.processes)
        # Descendants may survive their original process; retain the owned group identity.
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        for process in processes:
            try:
                process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in processes:
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def private_file(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w")


def adapter_environment(config_path, config):
    # Explicit configuration carries target identity; no inherited Production DB/token settings.
    return {key: os.environ[key] for key in ("PATH", "LANG", "HOME") if key in os.environ} | {
        "TSW92_TRIAL_CONFIG": str(config_path.resolve()),
        "TSW92_TOKEN_FILE": config["runner"]["token_file"],
    }


def invoke(children, adapter, env, payload, timeout):
    process = children.start([checked_adapter(adapter)], env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    process.stdin.write(json.dumps(payload).encode())
    process.stdin.close()
    deadline = time.monotonic() + timeout
    output = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
            raise Error("Trial adapter timed out")
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        output += chunk
        if len(output) > 1024 * 1024:
            raise Error("Trial adapter returned oversized evidence")
    process.wait(timeout=max(.01, deadline - time.monotonic()))
    process.stdout.close()
    children.release(process)
    if process.returncode:
        raise Error("Trial adapter failed")
    return json.loads(output)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Error("Redirects are forbidden for authenticated isolated requests")


def request(item, config, children, env):
    url = config["read_targets"][item["target"]]["origin"].rstrip("/") + item["path"]
    started = time.monotonic()
    headers = invoke(children, config["runner"]["adapters"]["signer"], env,
                     {"method": "GET", "url": url}, config["runner"]["request_timeout_seconds"])
    normalized = {key.lower(): value for key, value in headers.items()}
    if not isinstance(normalized.get("authorization"), str) or not normalized.get("dpop"):
        raise Error("Signer must supply existing authenticated OAuth/DPoP headers")
    if set(normalized) - {"authorization", "dpop", "accept"}:
        raise Error("Signer returned unsupported headers")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    for attempt in range(2):
        try:
            with opener.open(urllib.request.Request(url, headers=headers, method="GET"), timeout=config["runner"]["request_timeout_seconds"]) as response:
                size = 0
                while True:
                    chunk = response.read1(65536)
                    size += len(chunk)
                    if (response.status != 200 or size > 8 * 1024 * 1024
                            or time.monotonic() - started > 2 * config["runner"]["request_timeout_seconds"]):
                        raise Error("Read response failed or exceeded its byte/time bound")
                    if not chunk:
                        break
            break
        except urllib.error.HTTPError as error:
            nonce = error.headers.get("DPoP-Nonce")
            error.close()
            if attempt or error.code not in (400, 401) or not nonce:
                raise Error("Authenticated read failed") from None
            headers = invoke(children, config["runner"]["adapters"]["signer"], env,
                {"method": "GET", "url": url, "nonce": nonce}, config["runner"]["request_timeout_seconds"])
            names = {key.lower(): value for key, value in headers.items()}
            if not names.get("authorization") or not names.get("dpop") or set(names) - {"authorization", "dpop", "accept"}:
                raise Error("Signer returned unsupported retry headers")
    return {"id": item["id"], "category": item["category"], "latency_ms": (time.monotonic() - started) * 1000}


def load_interval(trace, phase, seconds, config, children, env, rng, request_log, coverage):
    rate = trace["rates"][phase]
    count = math.ceil(seconds * rate)
    start = time.time()
    clock = time.monotonic()
    futures = []
    pool = ThreadPoolExecutor(max_workers=config["runner"]["concurrency"])
    try:
        for index in range(count):
            delay = clock + index / rate - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            if sum(not future.done() for future in futures) >= config["runner"]["concurrency"]:
                raise Error("Offered load exceeded concurrency; do not hide backlog by queueing requests")
            futures.append(pool.submit(request, rng.choice(trace["requests"]), config, children, env))
        results = [future.result() for future in futures]
    except BaseException:
        children.stop()
        pool.shutdown(wait=False, cancel_futures=True)
        raise
    else:
        pool.shutdown(wait=True)
    delay = clock + seconds - time.monotonic()
    if delay > 0:
        time.sleep(delay)
    for result in results:
        coverage.add(result["category"])
        request_log.write(json.dumps({"time": time.time(), "phase": phase, **result}) + "\n")
    request_log.flush()
    latencies = sorted(result["latency_ms"] for result in results)
    return {"interval_start": start, "interval_end": time.time(), "phase": phase,
            "attempted": count, "successful": len(results), "p95_ms": latencies[math.ceil(len(latencies) * .95) - 1],
            **{key: config[key] for key in ("workload_sha256", "binary_manifest_sha256", "seed")}}


def progress_reader(process, name, events):
    try:
        for line in iter(lambda: process.stdout.readline(65537), b""):
            if len(line) > 65536 or not line.endswith(b"\n"):
                raise Error("Oversized worker progress evidence")
            event = json.loads(line)
            if type(event["completed"]) is not int or event["completed"] < 0:
                raise Error("Invalid worker completion count")
            events.put((name, event["completed"], time.monotonic()))
    except Exception:
        events.put((name, None, time.monotonic()))


def initial_probe(evidence, config):
    # No fabricated load is attached to this preflight observation.
    if (evidence["identity"] != {key: config["target"][key] for key in trial.IDENTITIES}
            or evidence["memory_max"] != config["memory_gib"] * trial.GIB
            or evidence["restore"]["snapshot_sha256"] != config["snapshot_sha256"]
            or evidence["restore"]["dataset"] != "full_snapshot"
            or evidence["restore"]["restored_bytes"] < config["minimum_restore_bytes"]
            or evidence["db"]["database_bytes"] < config["minimum_restore_bytes"]
            or evidence["volume_free_bytes"] < config["minimum_free_bytes"]
            or evidence["db"]["connections"] > config["maximum_connections"]
            or set(evidence["db"]["queues"]) != {"wire_ingestion_inbox", "appview_ingestion_inbox"}
            or any(q["rows_lower_bound"] > config["maximum_queue_rows"] or q["oldest_seconds"] > config["maximum_queue_age_seconds"] for q in evidence["db"]["queues"].values())
            or any(evidence["memory_events"][key] for key in ("oom", "oom_kill"))):
        raise Error("Initial database resource/snapshot preflight failed")


def check_progress(current, previous, config, seconds=60):
    for name in current:
        floor = config["runner"][f"minimum_{'rankings' if name == 'ranking' else name}_per_minute"]
        if current[name] - previous[name] < floor * seconds / 60:
            raise Error("Representative ingestion/ranking throughput floor was not met")


def run(config_path, trace_path, output):
    config = json.loads(config_path.read_text())
    trace = validate_inputs(config, trace_path)
    adapters = config["runner"]["adapters"]
    env = adapter_environment(config_path, config)
    children = Children()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    round_state = trial.Round(config)
    try:
        identity = invoke(children, adapters["identity"], env, {}, 30)
        expected = {"target": config["target"], "runner": {key: config["runner"][key] for key in ("project_id", "environment_id", "service_id")},
                    "read_targets": config["read_targets"], "snapshot_sha256": config["snapshot_sha256"]}
        if identity != expected:
            raise Error("Provider-verified service, volume, origin or snapshot identities do not match")
        initial_probe(invoke(children, adapters["probe"], env, {}, config["sample_seconds"]), config)
        events = queue.Queue(maxsize=10000)
        workers = {}
        progress = {name: 0 for name in ("replay", "ranking")}
        for name in progress:
            process = children.start([checked_adapter(adapters[name])], env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            workers[name] = process
            threading.Thread(target=progress_reader, args=(process, name, events), daemon=True).start()
        previous_progress = progress.copy()
        coverage = set()
        rng = random.Random(config["seed"])
        beginning = time.monotonic()
        progress_start = beginning
        restarted = False
        recovery_started = None
        receipt = None
        with private_file(output / "samples.jsonl") as samples, private_file(output / "requests.jsonl") as requests:
            while round_state.observed_seconds < config["observation_seconds"]:
                elapsed = time.monotonic() - beginning
                if elapsed > config["observation_seconds"] + config["restart_grace_seconds"] + 120:
                    raise Error("Round exceeded maximum wall time")
                if not restarted and elapsed >= config["restart_at_seconds"]:
                    receipt = invoke(children, adapters["restart"], env, {"previous_container_epoch": round_state.last["container_epoch"]}, config["restart_grace_seconds"])
                    restarted = True
                    recovery_started = time.monotonic()
                phase = "recovery" if recovery_started is not None and time.monotonic() - recovery_started < 610 else "burst" if 900 <= elapsed < 1210 else "mixed"
                load = load_interval(trace, phase, config["sample_seconds"], config, children, env, rng, requests, coverage)
                evidence = invoke(children, adapters["probe"], env, {}, config["sample_seconds"])
                evidence["load"] = load
                if receipt is not None:
                    evidence["restart_receipt"] = receipt
                    receipt = None
                while not events.empty():
                    name, count, _ = events.get_nowait()
                    if count is None or count < progress[name]:
                        raise Error("Worker evidence missing or completion counter regressed")
                    progress[name] = count
                evidence["worker_progress"] = progress.copy()
                # Preserve rejected samples as evidence, then stop every owned process.
                samples.write(json.dumps(evidence) + "\n"); samples.flush()
                round_state.accept(evidence)
                if any(process.poll() is not None for process in workers.values()):
                    raise Error("Owned replay or ranking worker exited early")
                if time.monotonic() - progress_start >= config["runner"]["throughput_window_seconds"]:
                    check_progress(progress, previous_progress, config, time.monotonic() - progress_start)
                    previous_progress = progress.copy()
                    progress_start = time.monotonic()
            if coverage != CATEGORIES:
                raise Error("Observed successful reads did not cover the reviewed workload categories")
            summary = round_state.finish()
            summary["worker_progress"] = progress.copy()
            summary["read_categories"] = sorted(coverage)
            with private_file(output / "summary.json") as handle:
                json.dump(summary, handle)
            return summary
    except BaseException as error:
        with private_file(output / "failure.json") as handle:
            json.dump({"status": "stopped", "reason": str(error) if isinstance(error, Error) else type(error).__name__,
                       "capacity_claim": "No passing capacity evidence"}, handle)
        raise
    finally:
        children.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        print(json.dumps(run(args.config, args.trace, args.output)))
    except (Exception, KeyboardInterrupt):
        # Adapter errors and request URLs may contain secrets; detailed raw exceptions stay out of logs.
        raise SystemExit("Memory trial stopped; retain private evidence and inspect adapter health.")


if __name__ == "__main__":
    main()
