#!/usr/bin/env python3
"""Sequential, bounded comparison of real Wire archive replay on an isolated Railway target.

Inputs are explicit old/new binaries and one identical SQL seed. This never creates
events, resets counters, rewinds source checkpoints, or connects to the normal DB.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class BenchmarkError(RuntimeError):
    pass


def validate_target(url):
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    options = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    ssl_modes = {"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}
    if (parsed.fragment or len(options) > 1
            or any(key != "sslmode" or value not in ssl_modes for key, value in options)):
        raise BenchmarkError("Connection URL permits only one supported sslmode option")
    if parsed.port == 0:
        raise BenchmarkError("Connection URL must use a valid nonzero port")
    local = host in {"localhost", "127.0.0.1", "::1"} and parsed.port not in {None, 5432}
    isolated_railway = bool(re.fullmatch(r"tsw92-[a-z0-9-]+\.railway\.internal", host))
    if parsed.scheme not in {"postgres", "postgresql"} or not (local or isolated_railway):
        raise BenchmarkError("Target must be a dedicated tsw92-*.railway.internal service or explicit nondefault loopback port")
    return parsed


def database_url(admin_url, database):
    parsed = validate_target(admin_url)
    if not re.fullmatch(r"tsw92_bench_[a-f0-9]{12}", database):
        raise BenchmarkError("Database name is not owned by this benchmark")
    return urllib.parse.urlunsplit(parsed._replace(path="/" + database))


def wal_delta(before, after):
    if before["stats_reset"] != after["stats_reset"]:
        raise BenchmarkError("WAL statistics reset during the observation; comparison is invalid")
    delta = int(after["wal_bytes"]) - int(before["wal_bytes"])
    if delta < 0:
        raise BenchmarkError("WAL counter moved backwards")
    return delta


def check_limits(sample, started, now, maximum_seconds, maximum_bytes):
    if now - started >= maximum_seconds:
        raise BenchmarkError("Replay reached the configured wall-clock deadline")
    if int(sample["cluster_bytes"]) + int(sample["wal_directory_bytes"]) >= maximum_bytes:
        raise BenchmarkError("Database plus WAL directory reached the configured byte cap")


def snapshot_complete(sample, before_seq):
    checkpoint = sample.get("checkpoint") or {}
    return (checkpoint.get("replay_state") == "snapshot_complete"
            and checkpoint.get("replay_before_seq") == before_seq
            and checkpoint.get("replay_sealed_seq") == before_seq
            and sample.get("actionable_count") == 0)


def stop_processes(processes):
    # Stop intake first; keep rank/read processes from writing while the DB is removed.
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
    deadline = time.monotonic() + 10
    for process in reversed(processes):
        try:
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


class Postgres:
    def __init__(self, binary):
        self.binary = binary

    def run(self, url, sql=None, file=None):
        # Credentials stay out of argv, process logs and evidence.
        connection = validate_target(url)
        env = {key:value for key,value in os.environ.items() if not key.startswith("PG")}
        env.update({"PGHOST":connection.hostname,"PGPORT":str(connection.port or 5432),
                    "PGUSER":urllib.parse.unquote(connection.username or "postgres"),
                    "PGPASSWORD":urllib.parse.unquote(connection.password or ""),
                    "PGDATABASE":urllib.parse.unquote(connection.path.removeprefix("/")),
                    "PGCONNECT_TIMEOUT":"5","PGAPPNAME":"tsw92-benchmark"})
        sslmode = urllib.parse.parse_qs(connection.query).get("sslmode",["prefer"])[0]
        env["PGSSLMODE"] = sslmode
        command = [self.binary, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
        command += ["-f", str(file)] if file else ["-c", sql]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60 if file else 12)
        if result.returncode:
            # psql errors can contain URL parameters or seed data; keep them private.
            raise BenchmarkError("PostgreSQL command failed (exit %s); no counter reset or source mutation attempted" % result.returncode)
        return result.stdout.strip()

    def query(self, url, sql):
        output = self.run(url, "BEGIN READ ONLY; SET LOCAL statement_timeout='5s'; " + sql + "; COMMIT;")
        return json.loads(output)


def sample_database(pg, url, generation):
    # generation is generated locally, never interpolated from a public event.
    if not re.fullmatch(r"wire-global-v4-tsw92-bench-[a-f0-9]{12}", generation):
        raise BenchmarkError("Invalid benchmark source identity")
    return pg.query(url, """
      SELECT json_build_object(
        'captured_at', now(),
        'wal', (SELECT row_to_json(w) FROM pg_stat_wal w),
        'cluster_bytes', (SELECT sum(pg_database_size(oid)) FROM pg_database WHERE datallowconn),
        'wal_directory_bytes', (SELECT coalesce(sum(size),0) FROM pg_ls_waldir()),
        'checkpoint', (SELECT row_to_json(c) FROM (
          SELECT replay_state,replay_before_seq,replay_sealed_seq,last_staged_seq
          FROM appview_jetstream_checkpoints WHERE environment='dev' AND source_generation='%s'
        ) c),
        'actionable_count', (SELECT count(*) FROM (
          SELECT 1 FROM wire_ingestion_inbox WHERE environment='dev' AND source_generation='%s'
            AND status IN ('pending','retry','leased') LIMIT 10001
        ) q),
        'oldest_actionable_seconds', (SELECT extract(epoch FROM now()-min(staged_at))
          FROM wire_ingestion_inbox WHERE environment='dev' AND source_generation='%s'
            AND status IN ('pending','retry','leased')),
        'dead_letters', (SELECT count(*) FROM (
          SELECT 1 FROM wire_ingestion_inbox WHERE environment='dev' AND source_generation='%s'
            AND status='dead_letter' LIMIT 10001
        ) d),
        'active_generation', (SELECT row_to_json(g) FROM (
          SELECT generation_id,generated_at,candidate_count,ranked_count,config_version,expires_at,
                 diagnostics->>'cycleDurationMilliseconds' AS cycle_duration_ms
          FROM wire_rank_generations WHERE feed_key='wire' AND language_bucket='und' AND is_active
        ) g),
        'latest_generation', (SELECT row_to_json(g) FROM (
          SELECT generation_id,generated_at,candidate_count,ranked_count,status,is_active,config_version,
                 diagnostics->>'cycleDurationMilliseconds' AS cycle_duration_ms
          FROM wire_rank_generations WHERE feed_key='wire' AND language_bucket='und'
          ORDER BY generated_at DESC LIMIT 1
        ) g),
        'generation_count', (SELECT count(*) FROM wire_rank_generations),
        'tables', (SELECT json_agg(t) FROM (
          SELECT relname,n_tup_ins,n_tup_upd,n_tup_del,n_live_tup,n_dead_tup
          FROM pg_stat_user_tables WHERE relname IN
            ('wire_ingestion_inbox','wire_items','wire_rank_generations','wire_ranked_items',
             'wire_signal_events','wire_signal_rollups') ORDER BY relname
        ) t)
      )
    """ % (generation, generation, generation, generation))


def archive_plan(config, api_key):
    host = config["archive_host"]
    if host != "https://jetstream.us-west.bsky.network":
        raise BenchmarkError("This benchmark is scoped to the verified US-West archive")
    payload = {"afterSeq": config["after_seq"], "beforeSeq": config["before_seq"],
               "collections": config["collections"]}
    request = urllib.request.Request(host + "/xrpc/network.bsky.jetstream.planSnapshot",
        data=json.dumps(payload).encode(), headers={"Authorization": "Bearer " + api_key,
                                                   "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=12) as response:
        plan = json.load(response)
    actual = sorted((s["name"], s["checksum"]) for s in plan["segments"])
    expected = sorted((s["name"], s["checksum"]) for s in config["archive_segments"])
    if actual != expected or plan["sealedTipSeq"] != config["before_seq"] or plan["plannedThroughSeq"] != config["before_seq"]:
        raise BenchmarkError("Archive identity/plan changed or needs pagination; refusing unmatched replay")
    return plan


def anonymous_gateway_headers(secret, path, timestamp):
    did = "did:web:thesocialwire.app:anonymous-discovery"
    canonical = "\n".join([str(timestamp),"GET",path.split("?",1)[0],did])
    signature = base64.urlsafe_b64encode(hmac.digest(secret.encode(),canonical.encode(),"sha256")).decode().rstrip("=")
    return {"X-SocialWire-Gateway-DID":did,"X-SocialWire-Gateway-Timestamp":str(timestamp),
            "X-SocialWire-Gateway-Signature":signature}


def read_probe(port, expected_generation, trust_secret=None):
    started = time.monotonic()
    path = "/xrpc/app.thesocialwire.discovery.getWire?limit=50"
    headers = anonymous_gateway_headers(trust_secret,path,int(time.time())) if trust_secret else {}
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (port,path),headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = json.load(response)
            return {"status": response.status, "seconds": time.monotonic()-started,
                    "generation_id": body.get("generationId"), "source": body.get("source"),
                    "degraded": body.get("degraded"), "item_count": len(body.get("items", [])),
                    "matches_local_active": body.get("generationId") == expected_generation}
    except urllib.error.HTTPError as error:
        return {"status": error.code, "seconds": time.monotonic()-started}
    except (urllib.error.URLError, TimeoutError):
        return {"status": 0, "seconds": time.monotonic()-started}


def start_process(binary, env, log_path):
    log = open(log_path, "wb")
    try:
        process = subprocess.Popen([str(Path(binary).resolve())], env=env, cwd=log_path.parent,
                                   stdout=log, stderr=subprocess.STDOUT)
    finally:
        log.close()
    return process


def process_environment(config, variant, url, generation, secrets):
    env = {k: os.environ[k] for k in ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "SSL_CERT_FILE") if k in os.environ}
    env.update({str(k): str(v) for k, v in config["common_environment"].items()})
    env.update(secrets)
    env.update({"DATABASE_URL": url, "APP_ENV": "dev", "BIND_HOST":"127.0.0.1", "WIRE_FEED_MODE": "api",
        "WIRE_EXTERNAL_SIGNAL_MODE": "off", "WIRE_RANK_INTERVAL_SECONDS": str(variant["rank_interval_seconds"]),
        "WIRE_GENERATION_RETENTION_SECONDS": str(variant["generation_retention_seconds"]),
        "WIRE_INBOX_SOURCE_GENERATIONS": generation,
        "WIRE_CORPUS_EDGE_BASE_URL": "", "WIRE_CORPUS_EDGE_SERVICE_ID": "", "WIRE_CORPUS_EDGE_HMAC_SECRET": "",
        "JETSTREAM_PIPELINE_MODE": "wire-global-v1", "JETSTREAM_SOURCE_GENERATION": generation,
        "JETSTREAM_LEADER_LEASE_NAME": generation, "JETSTREAM_HOST": config["archive_host"].removeprefix("https://"),
        "JETSTREAM_BOOTSTRAP_AFTER_SEQ": str(config["after_seq"]), "JETSTREAM_REPLAY_BEFORE_SEQ": str(config["before_seq"]),
        "JETSTREAM_COLLECTIONS": ",".join(config["collections"]), "JETSTREAM_REPLAY_SNAPSHOT_ONLY": "true",
        "JETSTREAM_EXIT_AFTER_SNAPSHOT": "true", "JETSTREAM_SEGMENT_STRIPES": "1"})
    return env


def run_variant(config, variant, pg, admin_url, output, secrets, generation, seed):
    database = "tsw92_bench_" + uuid.uuid4().hex[:12]
    url = database_url(admin_url, database)
    processes = []
    created = False
    result = {"variant": variant["name"], "revision": variant["revision"], "database": database}
    try:
        pg.run(admin_url, 'CREATE DATABASE "%s"' % database)
        created = True
        pg.run(url, file=seed)
        result["seed_sha256"] = hashlib.sha256(seed.read_bytes()).hexdigest()
        result["upgrade_sha256"] = []
        for upgrade in variant.get("upgrade_sql", []):
            path = Path(upgrade).resolve()
            result["upgrade_sha256"].append(hashlib.sha256(path.read_bytes()).hexdigest())
            pg.run(url, file=path)
        for key in ("ingest", "wire", "appview"):
            result[key + "_sha256"] = hashlib.sha256(Path(variant[key]).read_bytes()).hexdigest()
        initial = sample_database(pg, url, generation)
        check_limits(initial, 0, 0, config["maximum_seconds"], config["maximum_database_and_wal_bytes"])
        # Worker startup, ingestion, generation and reads all fall inside the observation.
        started = time.monotonic()
        base = process_environment(config, variant, url, generation, secrets)
        # Development intentionally requires Corpus Edge. Exercise the production
        # local-serving branch only inside this disposable, guarded database.
        processes.append(start_process(variant["appview"], dict(base, APP_ENV="prod", PORT="18081"), output / "appview.log"))
        processes.append(start_process(variant["wire"], dict(base, PORT="18082", WIRE_WORKER_ROLE="drain"), output / "drain.log"))
        processes.append(start_process(variant["wire"], dict(base, PORT="18083", WIRE_WORKER_ROLE="rank"), output / "rank.log"))
        processes.append(start_process(variant["ingest"], dict(base, PORT="18084"), output / "ingest.log"))
        completed_at = None
        good_reads = 0
        observed_generations = set()
        with open(output / "samples.jsonl", "w") as evidence:
            while True:
                sample = sample_database(pg, url, generation)
                elapsed = time.monotonic() - started
                sample["elapsed_seconds"] = elapsed
                check_limits(sample, started, time.monotonic(), config["maximum_seconds"], config["maximum_database_and_wal_bytes"])
                wal_delta(initial["wal"],sample["wal"])
                for index, process in enumerate(processes):
                    status = process.poll()
                    if status is not None and (index != 3 or status != 0):
                        raise BenchmarkError("Benchmark child exited before completion: index=%d status=%s" % (index,status))
                active = sample.get("active_generation") or {}
                probe = read_probe(18081, active.get("generation_id"), secrets["GATEWAY_APPVIEW_INTERNAL_SECRET"])
                sample["read"] = probe
                if probe.get("matches_local_active") and probe.get("source") == "ranked" and not probe.get("degraded") and probe.get("item_count",0)>0:
                    good_reads += 1
                    observed_generations.add(active["generation_id"])
                evidence.write(json.dumps(sample) + "\n")
                evidence.flush()
                if sample.get("dead_letters",0):
                    raise BenchmarkError("Isolated replay produced unresolved dead letters")
                if snapshot_complete(sample, config["before_seq"]) and processes[3].poll() == 0:
                    completed_at = completed_at or time.monotonic()
                if completed_at and time.monotonic()-completed_at >= config["settle_seconds"]:
                    if len(observed_generations)<2 or good_reads<config["minimum_successful_reads"]:
                        raise BenchmarkError("Real replay completed but insufficient nonempty local generations/reads for load acceptance")
                    result.update({"elapsed_seconds":elapsed,"wal_bytes":wal_delta(initial["wal"],sample["wal"]),
                                   "initial":initial,"final":sample,"successful_reads":good_reads,
                                   "observed_generations":len(observed_generations),"status":"passed"})
                    break
                time.sleep(config["sample_seconds"])
    except BaseException as error:
        result.update({"status":"failed", "error": type(error).__name__ + ": " + str(error)})
        raise
    finally:
        stopped = False
        try:
            stop_processes(processes)
            stopped = True
        except BaseException as error:
            result.update({"status":"failed", "cleanup_error":type(error).__name__,
                           "database_retained":database})
            raise
        finally:
            (output / "result.json").write_text(json.dumps(result,indent=2))
        # Only the random DB created by this call can be removed, after every child stopped.
        if created and stopped:
            pg.run(admin_url, 'DROP DATABASE "%s" WITH (FORCE)' % database)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if any(re.search(r"SECRET|PASSWORD|TOKEN|API_KEY|DATABASE_URL",key) for key in config["common_environment"]):
        raise BenchmarkError("Keep credentials out of configuration; only named environment inputs are accepted")
    admin_url = os.environ[config["admin_url_environment"]]
    validate_target(admin_url)
    if config["maximum_seconds"]>7200 or config["maximum_seconds"]<60 or not 1<=config["sample_seconds"]<=30:
        raise BenchmarkError("Use a 60–7200 second runtime and a 1–30 second sampling interval")
    if config["after_seq"]>=config["before_seq"] or len(config["variants"])!=2:
        raise BenchmarkError("Exactly two sequential variants and one positive sealed interval are required")
    for variant in config["variants"]:
        if not re.fullmatch(r"[a-f0-9]{40}",variant["revision"]) or variant["name"] not in {"baseline","candidate"}:
            raise BenchmarkError("Each variant requires an exact commit and baseline/candidate name")
    if [v["name"] for v in config["variants"]] != ["baseline","candidate"]:
        raise BenchmarkError("Variants must run baseline then candidate, sequentially")
    args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    api_key = os.environ[config["archive_key_environment"]]
    plan = archive_plan(config,api_key)
    (args.output/"archive-plan.json").write_text(json.dumps(plan,indent=2))
    pg = Postgres(config.get("psql","psql"))
    other_clients = pg.query(admin_url,"SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid()")
    if other_clients:
        raise BenchmarkError("Dedicated benchmark database server has other client connections; refuse contaminated WAL comparison")
    seed = Path(config["seed_sql"]).resolve()
    if seed.stat().st_size > 256*1024*1024:
        raise BenchmarkError("Use a bounded schema/public-input seed no larger than 256 MiB; full database copies need a separate restore drill")
    seed_hash = hashlib.sha256(seed.read_bytes()).hexdigest()
    (args.output/"configuration.json").write_text(json.dumps(config,indent=2))
    # Identical fresh source identity and HMAC material on both disposable seeded DBs.
    generation = "wire-global-v4-tsw92-bench-" + uuid.uuid4().hex[:12]
    secrets = {"JETSTREAM_API_KEY":api_key,"WIRE_ACTOR_HMAC_SECRET":uuid.uuid4().hex+uuid.uuid4().hex,
               "WIRE_CURSOR_HMAC_SECRET":uuid.uuid4().hex+uuid.uuid4().hex,
               "GATEWAY_APPVIEW_INTERNAL_SECRET":uuid.uuid4().hex+uuid.uuid4().hex}
    results=[]
    for variant in config["variants"]:
        if hashlib.sha256(seed.read_bytes()).hexdigest()!=seed_hash:
            raise BenchmarkError("Seed changed between variants")
        archive_plan(config,api_key)
        output=args.output/variant["name"]
        output.mkdir(mode=0o700)
        results.append(run_variant(config,variant,pg,admin_url,output,secrets,generation,seed))
    (args.output/"comparison.json").write_text(json.dumps(results,indent=2))


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except (BenchmarkError,KeyboardInterrupt) as error:
        raise SystemExit(str(error))
