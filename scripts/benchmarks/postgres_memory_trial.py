#!/usr/bin/env python3
"""Read-only full-snapshot memory evidence. Never restores, restarts, tunes, or drops a DB."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import math
import select
import sys
import time

SPEC = importlib.util.spec_from_file_location("replay", Path(__file__).with_name("postgres_replay.py"))
replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay)
Error = replay.BenchmarkError
GIB = 1024 ** 3
IDENTITIES = {"project_id": "RAILWAY_PROJECT_ID", "environment_id": "RAILWAY_ENVIRONMENT_ID",
              "service_id": "RAILWAY_SERVICE_ID", "volume_id": "RAILWAY_VOLUME_ID"}


def validate_config(config):
    target = config["target"]
    for key in IDENTITIES:
        if not re.fullmatch(r"[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}", target[key]):
            raise Error("Explicit canonical Railway identities are required")
    for key in ("service_id", "volume_id", "environment_id"):
        if target[key] in config["protected_source_ids"]:
            raise Error("Target identity belongs to a protected source")
    if not config["protected_source_ids"]:
        raise Error("Record source identities before observing an isolated target")
    if not re.fullmatch(r"tsw92-[a-z0-9-]+\.railway\.internal", target["host"]):
        raise Error("An isolated tsw92 Railway host is required")
    if not re.fullmatch(r"tsw92_memory_[a-f0-9]{12}", target["database"]):
        raise Error("Explicit isolated memory-trial database is required")
    if config["memory_gib"] not in (16, 12, 8):
        raise Error("Memory rounds must use 16, 12, or 8 GiB")
    for key in ("snapshot_sha256", "workload_sha256", "binary_manifest_sha256"):
        if not re.fullmatch(r"[a-f0-9]{64}", config[key]):
            raise Error("Content hashes are required for comparable rounds")
    if not 3600 <= config["observation_seconds"] <= 14400 or not 1 <= config["sample_seconds"] <= 30:
        raise Error("Use at least one hour, at most four hours, and 1–30 second samples")
    restart = config["restart_at_seconds"]
    if not 600 <= restart <= config["observation_seconds"] - 600:
        raise Error("Restart requires ten minutes of observation on each side")
    for key in ("minimum_free_bytes", "maximum_queue_age_seconds", "maximum_queue_rows",
                "maximum_p95_ms", "maximum_connections", "minimum_restore_bytes"):
        if isinstance(config[key], bool) or not isinstance(config[key], (int, float)) or not math.isfinite(config[key]) or config[key] <= 0:
            raise Error("Explicit positive stop thresholds are required")
    if config["maximum_queue_rows"] >= 10001:
        raise Error("Queue stop cap must be below the sampled lower-bound cap")
    if not 10 <= config["restart_grace_seconds"] <= 300:
        raise Error("Restart grace must be 10–300 seconds")
    return config


def target_identity(config, environment):
    actual = {key: environment.get(name) for key, name in IDENTITIES.items()}
    if any(actual[key] != config["target"][key] for key in IDENTITIES):
        raise Error("Probe must run inside the explicitly named isolated Postgres service and volume")
    return actual


def pairs(path):
    return {key: int(value) for key, value in (line.split() for line in path.read_text().splitlines())}


def sample(config, pg, environment=os.environ, cgroup=Path("/sys/fs/cgroup")):
    validate_config(config)
    identity = target_identity(config, environment)
    if not environment.get("RAILWAY_DEPLOYMENT_ID"):
        raise Error("Railway deployment epoch is required")
    url = environment[config["database_url_environment"]]
    parsed = replay.validate_target(url)
    if parsed.hostname != config["target"]["host"] or parsed.path != "/" + config["target"]["database"]:
        raise Error("Database connection does not match the isolated target")
    mount = Path(environment["RAILWAY_VOLUME_MOUNT_PATH"]).resolve()
    # The restore operator writes this attestation only after the full snapshot is restored.
    manifest = json.loads((mount / "memory-trial-snapshot.json").read_text())
    if (manifest.get("dataset") != "full_snapshot" or manifest.get("snapshot_sha256") != config["snapshot_sha256"]
            or manifest.get("restored_bytes", 0) < config["minimum_restore_bytes"]
            or not manifest.get("restore_epoch")):
        raise Error("Full-snapshot restore attestation is absent or mismatched")
    memory_limit = (cgroup / "memory.max").read_text().strip()
    if memory_limit != str(config["memory_gib"] * GIB):
        raise Error("Observed cgroup memory limit differs from this round")
    free = os.statvfs(mount)
    queue_sql = []
    for table in ("wire_ingestion_inbox", "appview_ingestion_inbox"):
        queue_sql.append("'%s', (SELECT json_build_object('rows_lower_bound', " % table
            + "(SELECT count(*) FROM (SELECT 1 FROM public.%s WHERE status IN ('pending','retry','leased') LIMIT 10001) q), " % table
            + "'oldest_seconds', coalesce((SELECT extract(epoch FROM now()-staged_at) FROM public.%s " % table
            + "WHERE status IN ('pending','retry','leased') ORDER BY staged_at LIMIT 1),0)))")
    database = pg.query(url, """SELECT json_build_object(
      'postmaster_started', pg_postmaster_start_time(),
      'database', current_database(), 'database_bytes', pg_database_size(current_database()),
      'wal', (SELECT row_to_json(w) FROM pg_stat_wal w),
      'wal_insert_lsn', pg_current_wal_insert_lsn()::text,
      'checkpointer', (SELECT row_to_json(c) FROM pg_stat_checkpointer c),
      'archiver', (SELECT row_to_json(a) FROM pg_stat_archiver a),
      'database_stats', (SELECT row_to_json(d) FROM pg_stat_database d WHERE datname=current_database()),
      'connections', (SELECT count(*) FROM pg_stat_activity),
      'queues', json_build_object(%s))""" % ",".join(queue_sql))
    return {"time": time.time(), "identity": identity, "memory_max": int(memory_limit),
            "memory_current": int((cgroup / "memory.current").read_text()),
            "memory_stat": pairs(cgroup / "memory.stat"), "memory_events": pairs(cgroup / "memory.events"),
            "container_epoch": [environment.get("RAILWAY_DEPLOYMENT_ID"), cgroup.stat().st_ino,
                                Path("/proc/sys/kernel/random/boot_id").read_text().strip()],
            "volume_free_bytes": free.f_bavail * free.f_frsize, "restore": {key: manifest[key] for key in
                ("dataset", "snapshot_sha256", "restored_bytes", "restore_epoch")}, "db": database}


class Round:
    """Streaming stop gates; missing/reset telemetry fails closed instead of claiming a pass."""
    def __init__(self, config):
        self.config = validate_config(config)
        self.first = self.last = None
        self.restart_count = 0
        self.phases = set()
        self.phase_seconds = {key: 0 for key in ("mixed", "burst", "recovery")}
        self.observed_seconds = 0
        self.wal_spans = []

    def accept(self, sample):
        c = self.config
        if not math.isfinite(sample["time"]):
            raise Error("Invalid sample timestamp")
        for key in IDENTITIES:
            if sample["identity"][key] != c["target"][key]:
                raise Error("Target identity changed")
        if sample["memory_max"] != c["memory_gib"] * GIB:
            raise Error("Memory limit changed within a round")
        if (sample["restore"]["snapshot_sha256"] != c["snapshot_sha256"]
                or sample["restore"]["dataset"] != "full_snapshot"
                or sample["restore"]["restored_bytes"] < c["minimum_restore_bytes"]):
            raise Error("Snapshot identity/cardinality attestation changed")
        if sample["volume_free_bytes"] < c["minimum_free_bytes"]:
            raise Error("Volume headroom below stop threshold")
        if sample["db"]["connections"] > c["maximum_connections"]:
            raise Error("Connection ceiling exceeded")
        if sample["db"]["database_bytes"] < c["minimum_restore_bytes"]:
            raise Error("Observed database is smaller than the reviewed snapshot floor")
        if set(sample["db"]["queues"]) != {"wire_ingestion_inbox", "appview_ingestion_inbox"}:
            raise Error("Both ingestion queues must be observed")
        for key in ("oom", "oom_kill"):
            if key not in sample["memory_events"]:
                raise Error("Required OOM telemetry is missing")
        load = sample["load"]  # Independently produced by the authenticated representative driver.
        if (load["workload_sha256"] != c["workload_sha256"] or load["binary_manifest_sha256"] != c["binary_manifest_sha256"]
                or load["seed"] != c["seed"] or load["phase"] not in ("mixed", "burst", "recovery")):
            raise Error("Workload identity or phase is not comparable")
        if (not math.isfinite(load["interval_end"]) or not math.isfinite(load["interval_start"])
                or abs(load["interval_end"] - sample["time"]) > c["sample_seconds"]
                or not 0 < load["interval_end"] - load["interval_start"] <= 2 * c["sample_seconds"]):
            raise Error("Load interval does not match this telemetry sample")
        if not math.isfinite(load["p95_ms"]) or load["p95_ms"] < 0 or load["attempted"] <= 0 or load["successful"] != load["attempted"] or load["p95_ms"] > c["maximum_p95_ms"]:
            raise Error("Missing successful load, request errors, or latency stop threshold exceeded")
        for queue in sample["db"]["queues"].values():
            if queue["oldest_seconds"] > c["maximum_queue_age_seconds"] or queue["rows_lower_bound"] > c["maximum_queue_rows"]:
                raise Error("Queue age/size stop threshold exceeded")
        self.phases.add(load["phase"])
        if self.first is None:
            self.first = sample
            if any(sample["memory_events"].get(key, 0) for key in ("oom", "oom_kill")):
                raise Error("Round started with unaccounted OOM events")
        else:
            previous = self.last
            gap = sample["time"] - previous["time"]
            if gap <= 0:
                raise Error("Sample clock moved backwards")
            elapsed = sample["time"] - self.first["time"]
            restarted = (sample["container_epoch"] != previous["container_epoch"]
                         or sample["db"]["postmaster_started"] != previous["db"]["postmaster_started"])
            if restarted:
                if (self.restart_count or abs(elapsed - c["restart_at_seconds"]) > c["restart_grace_seconds"]
                        or load["phase"] != "recovery" or gap > c["restart_grace_seconds"]):
                    raise Error("Unexpected restart or recovery exceeded deadline")
                receipt = sample.get("restart_receipt", {})
                if (receipt.get("previous_container_epoch") != previous["container_epoch"]
                        or receipt.get("termination_reason") != "operator_restart" or receipt.get("oom_killed") is not False):
                    raise Error("Independent provider restart/OOM receipt is required across epoch loss")
                self.restart_count += 1
                if any(sample["memory_events"].get(key, 0) for key in ("oom", "oom_kill")):
                    raise Error("Recovery reports OOM events")
            else:
                if gap > 2 * c["sample_seconds"]:
                    raise Error("Missing telemetry outside declared restart")
                self.observed_seconds += gap
                if load["phase"] == previous["load"]["phase"]:
                    self.phase_seconds[load["phase"]] += gap
                for key in ("oom", "oom_kill"):
                    if sample["memory_events"].get(key, 0) != previous["memory_events"].get(key, 0):
                        raise Error("OOM event or unexplained cgroup reset")
                for source in ("wal", "checkpointer", "archiver", "database_stats"):
                    if sample["db"][source]["stats_reset"] != previous["db"][source]["stats_reset"]:
                        raise Error("Statistics reset outside declared restart")
                replay.wal_delta(previous["db"]["wal"], sample["db"]["wal"])
                self.wal_spans.append(replay.wal_lsn_span_bytes(previous["db"]["wal_insert_lsn"], sample["db"]["wal_insert_lsn"]))
                if sample["db"]["archiver"]["failed_count"] != previous["db"]["archiver"]["failed_count"]:
                    raise Error("Archive failure or counter regression")
            if sample["restore"]["restore_epoch"] != previous["restore"]["restore_epoch"]:
                raise Error("Snapshot replaced during observation")
        self.last = sample

    def finish(self):
        if not self.last or self.observed_seconds < self.config["observation_seconds"]:
            raise Error("Less than the required measured hour; restart gaps do not count")
        if (self.restart_count != 1 or self.phases != {"mixed", "burst", "recovery"}
                or self.phase_seconds["burst"] < 300 or self.phase_seconds["recovery"] < 600):
            raise Error("Missing five-minute burst, ten-minute recovery load, or a verified restart")
        if any(queue["rows_lower_bound"] for queue in self.last["db"]["queues"].values()):
            raise Error("Final actionable backlog has not drained")
        return {"status": "passed_evidence_gates", "memory_gib": self.config["memory_gib"],
                "observed_seconds": self.observed_seconds, "phase_seconds": self.phase_seconds, "wal_lsn_span_bytes_excluding_restart_gap": sum(self.wal_spans),
                "capacity_claim": "Requires reviewed representative trace and authenticated QA; not a synthetic capacity proof"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("sample", "validate", "watch"))
    parser.add_argument("config", type=Path)
    parser.add_argument("--samples", type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if args.mode == "sample":
        print(json.dumps(sample(config, replay.Postgres(config.get("psql", "psql")))))
    elif args.mode == "watch":
        trial = Round(config)
        started = time.monotonic()
        # A supervising load launcher must stop its owned children when this pipe exits.
        buffer = b""
        while time.monotonic() - started < config["observation_seconds"] + config["restart_grace_seconds"] + 120:
            ready, _, _ = select.select([sys.stdin], [], [], config["restart_grace_seconds"])
            if not ready:
                raise Error("Probe/driver telemetry stopped; stop the load")
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > 1024 * 1024:
                raise Error("Oversized or unterminated telemetry record")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                trial.accept(json.loads(line))
                print(line.decode(), flush=True)
        if buffer:
            raise Error("Incomplete telemetry at stream end")
        print(json.dumps(trial.finish()), file=sys.stderr)
    else:
        if not args.samples:
            raise Error("A merged probe/driver JSONL evidence file is required")
        trial = Round(config)
        with args.samples.open() as samples:
            for line in samples:
                trial.accept(json.loads(line))
        print(json.dumps(trial.finish(), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (Error, KeyError, ValueError, OSError) as error:
        raise SystemExit("Memory evidence rejected: " + type(error).__name__ + (": " + str(error) if isinstance(error, Error) else ""))
