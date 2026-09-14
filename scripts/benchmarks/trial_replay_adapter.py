#!/usr/bin/env python3
"""Own real bounded Go archive intake and Swift drain; emit committed receipts only."""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request

SPEC = importlib.util.spec_from_file_location("replay_receipts", Path(__file__).with_name("trial_replay_receipts.py"))
receipts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipts)
Error = receipts.Error
ARCHIVE = "https://jetstream.us-west.bsky.network"
# No inherited application/provider credentials or namespaced/live ingestion flags.
DRAIN_KEYS = {"DATABASE_URL", "APP_ENV", "WIRE_ACTOR_HMAC_SECRET", "WIRE_INBOX_SOURCE_GENERATIONS",
    "WIRE_POSTGRES_MAX_CONNECTIONS", "WIRE_INBOX_BATCH_SIZE", "WIRE_INBOX_CONCURRENCY",
    "WIRE_INBOX_IDLE_MILLISECONDS", "WIRE_DEFERRED_RECOMMENDATIONS_ENABLED", "WIRE_DEPENDENCY_HYDRATION_ENABLED"}


class AdapterStopped(BaseException):
    """Cancellation must bypass the database-unavailable retry path."""


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def positive_integer(value, maximum):
    return type(value) is int and 0 < value <= maximum


def binary(spec):
    path = Path(spec["path"])
    if (not path.is_absolute() or path.is_symlink() or not path.is_file()
            or not os.access(path, os.X_OK) or digest(path) != spec["sha256"]):
        raise Error("Replay worker executable differs from its reviewed hash")
    return str(path)


def validate(config):
    receipt = receipts.scope(config)
    value = config["replay"]
    if value.get("module_sha256") != digest(__file__):
        raise Error("Replay adapter module differs from its reviewed hash")
    for name in ("ingest", "drain"):
        binary(value[name])
    manifest = Path(config["runner"]["binary_manifest_file"])
    if digest(manifest) != config["binary_manifest_sha256"]:
        raise Error("Replay binary manifest differs from reviewed evidence")
    workers = json.loads(manifest.read_text()).get("workers", {})
    if any(workers.get("replay_" + name) != value[name]["sha256"] for name in ("ingest", "drain")):
        raise Error("Both real replay worker hashes must appear in the binary manifest")
    runtime_path = receipts.provider.private_path(receipt["runtime_environment_file"])
    if runtime_path.stat().st_size > 65536 or digest(runtime_path) != receipt["runtime_environment_sha256"]:
        raise Error("Replay runtime environment differs from its reviewed hash")
    runtime = json.loads(runtime_path.read_text())
    if (not isinstance(runtime, dict) or any(not isinstance(k, str) or not isinstance(v, str) or "\0" in v for k, v in runtime.items())
            or any(not runtime.get(key, "").strip() for key in ("DATABASE_URL", "APP_ENV", "WIRE_ACTOR_HMAC_SECRET", "JETSTREAM_API_KEY"))
            or runtime.get("APP_ENV") != receipt["environment"]
            or runtime.get("WIRE_INBOX_SOURCE_GENERATIONS") != receipt["source_generation"]
            or runtime.get("JETSTREAM_SOURCE_GENERATION") != receipt["source_generation"]):
        raise Error("Replay requires the reviewed isolated database, exact source and private worker credentials")
    for key, maximum in (("WIRE_POSTGRES_MAX_CONNECTIONS", 64), ("WIRE_INBOX_BATCH_SIZE", 5000),
                          ("WIRE_INBOX_CONCURRENCY", 64), ("WIRE_INBOX_IDLE_MILLISECONDS", 60000)):
        raw = runtime.get(key, "")
        if not raw.isdecimal() or not positive_integer(int(raw), maximum):
            raise Error("Specify reviewed drain pool, concurrency, batch and idle limits explicitly")
    for key in ("WIRE_DEFERRED_RECOMMENDATIONS_ENABLED", "WIRE_DEPENDENCY_HYDRATION_ENABLED"):
        if runtime.get(key) not in {"true", "false"}:
            raise Error("Review deferred recommendation and dependency settings explicitly")
    if value.get("archive_host") != ARCHIVE:
        raise Error("Replay archive is restricted to the reviewed US-West provider")
    collections = value.get("collections")
    if (not isinstance(collections, list) or not 1 <= len(collections) <= 32 or len(set(collections)) != len(collections)
            or any(not isinstance(x, str) or not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]*(?:\.[a-zA-Z][a-zA-Z0-9]*){2,}", x) for x in collections)):
        raise Error("Review a bounded exact collection inventory")
    segments = value.get("archive_segments")
    if (not isinstance(segments, list) or not 1 <= len(segments) <= 10000
            or any(not isinstance(s, dict) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,256}", s.get("name", ""))
                   or not re.fullmatch(r"[a-f0-9]{16,128}", s.get("checksum", "")) for s in segments)
            or len({s["name"] for s in segments}) != len(segments)):
        raise Error("Pin exact bounded archive segment names and checksums")
    for key, maximum in (("batch_size", 10000), ("admission_burst", 10000), ("maximum_inbox_rows", 10000),
            ("maximum_database_bytes", 500_000_000_000), ("incident_bytes", 100_000_000_000),
            ("daily_bytes", 100_000_000_000), ("maximum_runtime_seconds", 15000),
            ("maximum_unavailable_seconds", 300), ("sample_seconds", 30),
            ("ingest_port", 65535), ("drain_port", 65535)):
        if not positive_integer(value.get(key), maximum):
            raise Error("Replay bounds must be explicit positive integers")
    rate = value.get("admission_rate_per_second")
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or not 0 < rate <= 10000:
        raise Error("Replay admission rate must be finite, positive and bounded")
    events = value.get("reviewed_matching_events")
    if (not positive_integer(events, receipt["before_seq"] - receipt["after_seq"])
            or not isinstance(value.get("source_evidence"), str) or not 0 < len(value["source_evidence"]) <= 512):
        raise Error("Review actual matching-event inventory and retain its source evidence")
    minimum_load_seconds = config["observation_seconds"] - config["runner"]["throughput_window_seconds"]
    offered_seconds = (events - value["admission_burst"]) / rate
    if not minimum_load_seconds <= offered_seconds <= config["observation_seconds"]:
        raise Error("Reviewed archive pacing cannot cover and finish the fixed representative observation")
    if (value["maximum_runtime_seconds"] < config["observation_seconds"] + config["restart_grace_seconds"] + 120
            or value["maximum_unavailable_seconds"] > config["restart_grace_seconds"]
            or value["sample_seconds"] > config["sample_seconds"]
            or value["admission_burst"] > value["batch_size"] or value["daily_bytes"] < value["incident_bytes"]
            or value["maximum_inbox_rows"] > config["maximum_queue_rows"]
            or value["ingest_port"] == value["drain_port"]):
        raise Error("Replay pacing, resource bounds or runtime contradict the measured trial")
    ports = [value["ingest_port"], value["drain_port"]]
    for key in ("PORT", "INDEXING_APPVIEW_HEALTH_PORT", "INDEXING_WIRE_HEALTH_PORT"):
        raw = runtime.get(key, "")
        if not raw.isdecimal() or not positive_integer(int(raw), 65535):
            raise Error("Review explicit Coordinator and component health ports in the shared runtime")
        ports.append(int(raw))
    if len(set(ports)) != 5:
        raise Error("Replay and Coordinator require five distinct local listener ports")
    return value, runtime


def verify_private_runner(config, client=None):
    # Go's actual health server binds all interfaces. Never pretend BIND_HOST
    # changes it: verify the dedicated runner has no external ingress instead.
    client = client or receipts.provider.Provider(config)
    result = client.query("query($project:String!,$environment:String!,$service:String!){"
        "domains(projectId:$project,environmentId:$environment,serviceId:$service){"
        "serviceDomains{__typename} customDomains{__typename}}"
        "tcpProxies(environmentId:$environment,serviceId:$service){__typename}}",
        {"project": config["runner"]["project_id"], "environment": config["runner"]["environment_id"],
         "service": config["runner"]["service_id"]})
    domains = result.get("domains", {})
    lists = [domains.get("serviceDomains"), domains.get("customDomains"), result.get("tcpProxies")]
    if any(not isinstance(items, list) or items for items in lists):
        raise Error("Replay runner must have no public/custom domains or TCP proxies")


def child_environments(config, runtime, environment=os.environ):
    value, source = config["replay"], receipts.scope(config)
    base = {k: environment[k] for k in ("PATH", "LANG", "RAILWAY_PROJECT_ID", "RAILWAY_ENVIRONMENT_ID",
            "RAILWAY_SERVICE_ID", "RAILWAY_DEPLOYMENT_ID") if k in environment}
    drain = base | {key: runtime[key] for key in DRAIN_KEYS if key in runtime}
    drain.update(WIRE_WORKER_ROLE="drain", WIRE_FEED_MODE="shadow", WIRE_EXTERNAL_SIGNAL_MODE="off",
                 PORT=str(value["drain_port"]), BIND_HOST="127.0.0.1")
    ingest = base | {key: runtime[key] for key in ("DATABASE_URL", "APP_ENV", "JETSTREAM_API_KEY")}
    ingest.update({"JETSTREAM_PIPELINE_MODE": "wire-global-v1", "JETSTREAM_HOST": ARCHIVE.removeprefix("https://"),
        "JETSTREAM_SOURCE_GENERATION": source["source_generation"], "JETSTREAM_LEADER_LEASE_NAME": source["source_generation"],
        "JETSTREAM_BOOTSTRAP_AFTER_SEQ": str(source["after_seq"]), "JETSTREAM_REPLAY_BEFORE_SEQ": str(source["before_seq"]),
        "JETSTREAM_REPLAY_SNAPSHOT_ONLY": "true", "JETSTREAM_EXIT_AFTER_SNAPSHOT": "false",
        "JETSTREAM_COLLECTIONS": ",".join(value["collections"]), "JETSTREAM_SEGMENT_STRIPES": "1",
        "JETSTREAM_DOWNLOAD_CONCURRENCY": "1", "JETSTREAM_MAX_DOWNLOAD_ATTEMPTS": "3",
        "JETSTREAM_BATCH_SIZE": str(value["batch_size"]), "PORT": str(value["ingest_port"]),
        "JETSTREAM_REPLAY_INCIDENT_BYTES": str(value["incident_bytes"]), "JETSTREAM_REPLAY_DAILY_BYTES": str(value["daily_bytes"]),
        "WIRE_ADMISSION_RATE_PER_SECOND": str(value["admission_rate_per_second"]),
        "WIRE_ADMISSION_BURST_EVENTS": str(value["admission_burst"]),
        "WIRE_INBOX_MAX_ROWS": str(value["maximum_inbox_rows"]), "WIRE_DATABASE_MAX_BYTES": str(value["maximum_database_bytes"])})
    return ingest, drain


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise Error("Archive redirects are forbidden")


def verify_archive(config, api_key, opener=None):
    value, source = config["replay"], receipts.scope(config)
    body = json.dumps({"afterSeq": source["after_seq"], "beforeSeq": source["before_seq"], "collections": value["collections"]}).encode()
    request = urllib.request.Request(ARCHIVE + "/xrpc/network.bsky.jetstream.planSnapshot", data=body,
        headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json"})
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=10) as response:
        raw = response.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise Error("Archive plan exceeds its evidence bound")
    plan = json.loads(raw)
    if (sorted((s["name"], s["checksum"]) for s in plan["segments"])
            != sorted((s["name"], s["checksum"]) for s in value["archive_segments"])
            or plan.get("sealedTipSeq") != source["before_seq"] or plan.get("plannedThroughSeq") != source["before_seq"]
            or plan.get("cursor") or plan.get("nextCursor")):
        raise Error("Archive plan changed, is unsealed or needs pagination")


class OwnedWorkers:
    """Children inherit the supervisor-owned group; none can detach from its kill backstop."""
    def __init__(self):
        self.processes = {}

    def start(self, name, executable, environment):
        process = subprocess.Popen([executable], env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes[name] = process
        return process

    def check(self):
        for name, process in self.processes.items():
            if process.poll() is not None:
                raise Error("Owned " + name + " worker exited (status " + str(process.returncode) + "); no automatic restart")

    def stop(self):
        # Intake first. The final group kill also retires unexpected descendants.
        for name in ("ingest", "drain"):
            process = self.processes.get(name)
            if process is not None and process.poll() is None:
                process.terminate()
        deadline = time.monotonic() + 2
        for process in self.processes.values():
            try:
                process.wait(timeout=max(.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=.5)


def watch_owner(parent, stopped):
    while not stopped.wait(.25):
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
            return


def run(config):
    # Only the runner creates this new session/group. Never target a caller's group.
    if os.getsid(0) != os.getpid() or os.getpgrp() != os.getpid():
        raise Error("Replay adapter must be its runner-owned session and process-group leader")
    parent = os.getppid()
    if parent <= 1:
        raise Error("Replay owner was lost before startup")
    value, runtime = validate(config)
    evidence_path = Path(value["evidence_file"])
    if not evidence_path.is_absolute() or not evidence_path.parent.is_dir():
        raise Error("Use an absolute private replay evidence output path")
    handle = os.fdopen(os.open(evidence_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w")
    workers = OwnedWorkers()
    owner_stopped = threading.Event()
    def record(event):
        handle.write(json.dumps({"time": time.time(), **event}) + "\n"); handle.flush()
    def stopped(_number, _frame):
        raise AdapterStopped("Replay adapter cancelled or reached its absolute deadline")
    signal.signal(signal.SIGTERM, stopped); signal.signal(signal.SIGINT, stopped); signal.signal(signal.SIGALRM, stopped)
    signal.setitimer(signal.ITIMER_REAL, value["maximum_runtime_seconds"])
    try:
        threading.Thread(target=watch_owner, args=(parent, owner_stopped), daemon=True).start()
        # Full provider + restore verification precedes archive access and receipt DDL.
        pg, url = receipts.verified_connection(config)
        verify_private_runner(config)
        verify_archive(config, runtime["JETSTREAM_API_KEY"])
        pg.run(url, receipts.installation_sql(config), statement_timeout_seconds=5)
        environments = child_environments(config, runtime)
        for name, child_env in (("drain", environments[1]), ("ingest", environments[0])):
            process = workers.start(name, binary(value[name]), child_env)
            record({"event": "worker_started", "worker": name, "pid": process.pid, "sha256": value[name]["sha256"]})
        previous = 0
        unavailable_since = None
        exposure_checked_at = time.monotonic()
        while True:
            started = time.monotonic()
            workers.check()
            if started - exposure_checked_at >= 60:
                verify_private_runner(config)
                exposure_checked_at = time.monotonic()
            try:
                observed = pg.query(url, receipts.progress_sql(config))
            except Exception:
                workers.check()
                if unavailable_since is None:
                    unavailable_since = started
                    record({"event": "receipt_query_unavailable"})
                if time.monotonic() - unavailable_since >= value["maximum_unavailable_seconds"]:
                    raise Error("Receipt database availability exceeded its bounded grace") from None
            else:
                workers.check()
                progress = receipts.validated_progress(config, observed)
                if progress["completed"] < previous:
                    raise Error("Committed acknowledgement count regressed")
                previous = progress["completed"]
                if unavailable_since is not None:
                    record({"event": "receipt_query_recovered", "unavailable_seconds": time.monotonic() - unavailable_since})
                unavailable_since = None
                record({"event": "progress", **progress})
                print(json.dumps(progress), flush=True)
            time.sleep(max(.01, value["sample_seconds"] - (time.monotonic() - started)))
    except BaseException as error:
        record({"event": "stopped", "reason": str(error) if isinstance(error, Error) else type(error).__name__,
                "worker_exit_status": {name: process.poll() for name, process in workers.processes.items()}})
        raise
    finally:
        owner_stopped.set()
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            workers.stop()
        finally:
            handle.close()
            # Includes this adapter and any descendants surviving their direct parent.
            # The outer runner retains the same owned-group identity as a backstop.
            os.killpg(os.getpid(), signal.SIGKILL)


def main():
    try:
        run(json.loads(Path(os.environ["TSW92_TRIAL_CONFIG"]).read_text()))
    except BaseException:
        print("Real replay adapter failed; inspect private evidence and retain the isolated database.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
