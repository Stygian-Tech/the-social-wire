#!/usr/bin/env python3
"""Own the existing Coordinator and observe committed cycles on an isolated Railway trial."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

import railway_memory_adapters as provider_tools
import trial_replay_receipts as replay_receipts
from memory_ranking_evidence import RankingError, RankingEvidence, observation_sql

IDENTITY_KEYS = ("RAILWAY_PROJECT_ID", "RAILWAY_ENVIRONMENT_ID", "RAILWAY_SERVICE_ID", "RAILWAY_DEPLOYMENT_ID")
ENVIRONMENT_KEYS = {
    "DATABASE_URL", "APP_ENV", "REDIS_URL", "APPVIEW_CACHE_BACKEND", "ENABLE_THIN_APPVIEW",
    "JETSTREAM_SOURCE_GENERATION", "JETSTREAM_LEADER_LEASE_NAME", "DATABASE_DRIVER",
    "OPERATIONS_TELEMETRY_ENABLED", "OPERATIONS_RECOVERY_ENABLED", "OPERATIONS_BACKFILL_FINGERPRINT_SECRET",
    "PORT", "INDEXING_APPVIEW_HEALTH_PORT", "INDEXING_WIRE_HEALTH_PORT",
    "INDEXING_ROLE_LEASE_SECONDS", "INDEXING_ROLE_LEASE_RENEW_SECONDS", "INDEXING_ROLE_STANDBY_RETRY_SECONDS",
    "REDIS_POOL_MIN", "REDIS_POOL_MAX", "REDIS_COMMAND_TIMEOUT_MILLISECONDS",
}
INPUT_ONLY_KEYS = {"JETSTREAM_API_KEY"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RankingError(message)


def load_runtime(config):
    provider_tools.validate_config(config)
    receipt = replay_receipts.scope(config)
    settings = config["ranking"]
    for key, minimum, maximum in (("sample_seconds", 10, 30), ("maximum_stale_seconds", 60, 720),
                                  ("maximum_runtime_seconds", 1, 15000)):
        require(type(settings[key]) is int and minimum <= settings[key] <= maximum, "Ranking observation bounds invalid")
    require(settings["maximum_runtime_seconds"] >= config["observation_seconds"] + config["restart_grace_seconds"] + 120,
            "Ranking lifetime cannot end before the bounded parent round")
    languages = settings["supported_languages"]
    require(isinstance(languages, list) and 1 <= len(languages) <= 13 and len(set(languages)) == len(languages)
            and "und" in languages and all(isinstance(v, str) and re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9]{2,8})?", v) for v in languages),
            "Explicit complete reviewed language inventory required")
    require(settings["config_version"] == "wire-v10", "Only the existing baseline ranking algorithm is supported")
    sources = settings["source_generations"]
    require(sources == [receipt["source_generation"]], "Ranking and replay require the same exact reviewed source")
    require(settings["runtime_environment_file"] == receipt["runtime_environment_file"]
        and settings["runtime_environment_sha256"] == receipt["runtime_environment_sha256"],
        "Ranking and replay must share the reviewed private runtime environment")
    path = provider_tools.private_path(settings["runtime_environment_file"])
    require(path.stat().st_size <= 65536 and digest(path) == settings["runtime_environment_sha256"], "Reviewed private runtime environment changed")
    runtime = json.loads(path.read_text())
    require(isinstance(runtime, dict) and all(isinstance(k, str) and isinstance(v, str) and "\0" not in v
        and (k in ENVIRONMENT_KEYS | INPUT_ONLY_KEYS or re.fullmatch(r"(?:WIRE|THIN_APPVIEW)_[A-Z0-9_]+", k)) for k, v in runtime.items()),
        "Runtime environment contains an unreviewed process or credential setting")
    runtime = {key: value for key, value in runtime.items() if key not in INPUT_ONLY_KEYS}
    ports = [runtime.get(key, "") for key in ("PORT", "INDEXING_APPVIEW_HEALTH_PORT", "INDEXING_WIRE_HEALTH_PORT")]
    replay_ports = [config["replay"][key] for key in ("ingest_port", "drain_port")]
    require(all(re.fullmatch(r"[0-9]{1,5}", value) and 1 <= int(value) <= 65535 for value in ports)
        and all(type(value) is int and 1 <= value <= 65535 for value in replay_ports)
        and len(set(map(int, ports)) | set(replay_ports)) == 5,
        "Coordinator and replay require five distinct explicit health ports")
    require(runtime.get("APP_ENV") == "dev" and runtime.get("ENABLE_THIN_APPVIEW") == "true"
        and runtime.get("APPVIEW_CACHE_BACKEND") == "redis" and runtime.get("WIRE_FEED_MODE") in {"api", "visible"}
        and runtime.get("WIRE_EXTERNAL_SIGNAL_MODE") == "off" and runtime.get("WIRE_LANGUAGE_BUCKET") == "und"
        and runtime.get("WIRE_INBOX_SOURCE_GENERATIONS") == ",".join(sources)
        and runtime.get("JETSTREAM_SOURCE_GENERATION") in sources,
        "Coordinator runtime differs from the reviewed isolated baseline and replay scope")
    connection = provider_tools.trial.replay.validate_target(runtime["DATABASE_URL"])
    require(connection.hostname == config["target"]["host"] and connection.path == "/" + config["target"]["database"]
        and (connection.port or 5432) == 5432, "Coordinator database differs from verified target")
    redis = settings["redis_target"]
    require(provider_tools.uuid(redis["service_id"]) not in provider_tools.PROTECTED | set(config["protected_source_ids"])
        | {config["target"]["service_id"], config["runner"]["service_id"]}
        and re.fullmatch(r"tsw92-[a-z0-9-]+\.railway\.internal", redis["host"])
        and redis["port"] == 6379, "Explicit separate isolated Redis service required")
    redis_url = urllib.parse.urlsplit(runtime["REDIS_URL"])
    require(redis_url.scheme == "redis" and redis_url.hostname == redis["host"] and (redis_url.port or 6379) == redis["port"]
        and redis_url.path in ("", "/", "/0") and not redis_url.query and not redis_url.fragment,
        "Coordinator Redis differs from the isolated private target")
    binary = Path(settings["binary"]["path"])
    require(binary.is_absolute() and binary.name == "IndexingWorker" and binary.is_file() and not binary.is_symlink()
        and os.access(binary, os.X_OK) and digest(binary) == settings["binary"]["sha256"], "Reviewed real IndexingWorker binary required")
    psql = Path(settings["psql"])
    require(psql.is_absolute() and psql.is_file() and os.access(psql, os.X_OK), "Explicit psql executable required")
    manifest = Path(config["runner"]["binary_manifest_file"])
    require(digest(manifest) == config["binary_manifest_sha256"], "Reviewed binary manifest changed")
    pinned = json.loads(manifest.read_text())
    require(pinned["ranking"] == {"binary_sha256": settings["binary"]["sha256"],
        "runtime_environment_sha256": settings["runtime_environment_sha256"],
        "evidence_module_sha256": digest(Path(__file__).with_name("memory_ranking_evidence.py"))}
        and pinned["adapters"]["ranking"] == digest(__file__), "Ranking runtime or evidence helper is not pinned")
    return runtime


def verify_redis(provider, identity):
    config = provider.config
    expected = config["ranking"]["redis_target"]
    variables = {"environment": config["target"]["environment_id"], "service": expected["service_id"],
        "network": identity["privateNetworks"][0]["publicId"]}
    data = provider.query("""query($environment:String!,$service:String!,$network:String!){
      service:serviceInstance(environmentId:$environment,serviceId:$service){id environmentId serviceId serviceName
        activeDeployments{id projectId environmentId serviceId status instances{id status}}}
      endpoint:privateNetworkEndpoint(environmentId:$environment,serviceId:$service,privateNetworkId:$network){
        serviceInstanceId dnsName newDnsName deletedAt}}""", variables)
    service, endpoint = data["service"], data["endpoint"]
    require(service["environmentId"] == variables["environment"] and service["serviceId"] == variables["service"]
        and service["serviceName"].startswith("tsw92-") and len(service["activeDeployments"]) == 1,
        "Redis service identity changed")
    deployment = service["activeDeployments"][0]
    require(deployment["projectId"] == provider_tools.PROJECT and deployment["environmentId"] == variables["environment"]
        and deployment["serviceId"] == variables["service"] and deployment["status"] == "SUCCESS"
        and len(deployment["instances"]) == 1 and deployment["instances"][0]["status"] == "RUNNING"
        and endpoint["serviceInstanceId"] == service["id"] and endpoint["deletedAt"] is None
        and endpoint["newDnsName"] in (None, endpoint["dnsName"])
        and endpoint["dnsName"] + "." + identity["privateNetworks"][0]["dnsName"] + ".internal" == expected["host"],
        "Redis deployment or private endpoint is not isolated")


def observe(config, runtime, after):
    connection = provider_tools.trial.replay.validate_target(runtime["DATABASE_URL"])
    environment = {key: os.environ[key] for key in ("PATH", "LANG") if key in os.environ}
    environment.update(PGHOST=connection.hostname, PGPORT=str(connection.port or 5432),
        PGUSER=urllib.parse.unquote(connection.username or "postgres"), PGPASSWORD=urllib.parse.unquote(connection.password or ""),
        PGDATABASE=urllib.parse.unquote(connection.path[1:]), PGCONNECT_TIMEOUT="2", PGAPPNAME="tsw92-ranking-observer",
        PGSSLMODE=urllib.parse.parse_qs(connection.query).get("sslmode", ["prefer"])[0])
    sql = "BEGIN READ ONLY; SET LOCAL statement_timeout='2s'; SET LOCAL lock_timeout='500ms'; " + observation_sql(after) + "; COMMIT;"
    # Inherit the runner-owned process group, so forced outer cleanup includes this query too.
    process = subprocess.Popen([config["ranking"]["psql"], "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        output, _ = process.communicate(sql.encode(), timeout=3)
        if process.returncode:
            raise OSError("Ranking observation unavailable")
        require(len(output) <= 2 * 1024 * 1024, "Ranking observation exceeds byte bound")
        return json.loads(output)
    except subprocess.TimeoutExpired:
        raise OSError("Ranking observation unavailable") from None
    finally:
        if process.poll() is None: process.kill()
        process.wait()
        process.stdin.close(); process.stdout.close()


def child_environment(runtime, owner, observed=os.environ):
    return runtime | {key: observed[key] for key in (*IDENTITY_KEYS, "PATH", "LANG") if key in observed} | {
        "HOSTNAME": owner, "INDEXING_WORKER_ROLE": "coordinator", "BIND_HOST": "127.0.0.1"}


def emit(handle, event):
    line = json.dumps(event, separators=(",", ":")) + "\n"
    require(len(line.encode()) <= 65536 and handle.tell() + len(line.encode()) <= 16 * 1024 * 1024,
        "Ranking evidence exceeds its reviewed output bound")
    handle.write(line); handle.flush()
    sys.stdout.write(line); sys.stdout.flush()


def run(config):
    runtime = load_runtime(config)
    require(all(os.environ.get(provider_tools.trial.IDENTITIES[key]) == config["runner"][key]
        for key in ("project_id", "environment_id", "service_id")), "Ranking must run inside the named isolated runner")
    provider = provider_tools.Provider(config)
    identity = provider.identity()
    require(os.environ.get("RAILWAY_DEPLOYMENT_ID") == identity["runner"]["activeDeployments"][0]["id"], "Runner deployment changed")
    provider.probe(identity)
    verify_redis(provider, identity)
    baseline = observe(config, runtime, 0)
    owner = "tsw92-ranking-" + uuid.uuid4().hex
    state = RankingEvidence(config, owner, baseline, time.monotonic())
    evidence_path = Path(config["ranking"]["evidence_file"])
    require(evidence_path.is_absolute(), "Ranking evidence needs an explicit private absolute path")
    with os.fdopen(os.open(evidence_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        child = subprocess.Popen([config["ranking"]["binary"]["path"]], env=child_environment(runtime, owner),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # No alternate generation implementation, --once shortcut, or unfenced WireWorker rank entrypoint.
        emit(handle, state.event("started", baseline["observed_at"]) | {"owner_id": owner})
        unavailable_since = None
        while True:
            require(child.poll() is None, "Owned Coordinator exited before trial completion")
            state.check_stale(time.monotonic())
            try:
                sample = observe(config, runtime, state.after)
            except OSError:
                unavailable_since = unavailable_since or time.monotonic()
                require(time.monotonic() - unavailable_since <= config["restart_grace_seconds"], "Ranking observation stayed unavailable")
                emit(handle, state.event("unavailable"))
            else:
                unavailable_since = None
                emit(handle, state.accept(sample, time.monotonic()))
            time.sleep(config["ranking"]["sample_seconds"])


def watch_owner(parent, deadline, stopped):
    while not stopped.wait(.25):
        if os.getppid() != parent or time.monotonic() >= deadline:
            os.kill(os.getpid(), signal.SIGTERM)
            return


def retire_session(grace=1):
    # The outer runner created this session. Never kill a shared shell/test process group.
    require(os.getsid(0) == os.getpid() and os.getpgrp() == os.getpid(), "Adapter does not own its session")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    os.killpg(os.getpid(), signal.SIGTERM)
    time.sleep(grace)
    # Includes this supervisor: a surviving descendant cannot outlive its bounded owner.
    os.killpg(os.getpid(), signal.SIGKILL)


def main():
    require(os.getsid(0) == os.getpid() and os.getpgrp() == os.getpid(), "Invoke ranking through the owned trial runner")
    parent = os.getppid()
    def cancelled(*_): raise RankingError("Ranking adapter cancelled")
    signal.signal(signal.SIGTERM, cancelled); signal.signal(signal.SIGINT, cancelled)
    stopped = threading.Event()
    try:
        require(parent > 1, "Ranking parent was lost before startup")
        config = json.loads(Path(os.environ["TSW92_TRIAL_CONFIG"]).read_text())
        maximum = config["ranking"]["maximum_runtime_seconds"]
        require(type(maximum) is int and 1 <= maximum <= 15000, "Ranking lifetime invalid")
        watchdog = threading.Thread(target=watch_owner, args=(parent, time.monotonic() + maximum, stopped), daemon=True)
        watchdog.start()
        run(config)
    except BaseException:
        # Runtime configuration and driver errors may contain secrets; emit only a fixed diagnostic.
        print("Owned ranking adapter stopped; inspect its bounded private evidence and isolated service health.", file=sys.stderr, flush=True)
    finally:
        stopped.set()
        retire_session()


if __name__ == "__main__": main()
