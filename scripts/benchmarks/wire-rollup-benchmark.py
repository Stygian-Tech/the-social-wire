#!/usr/bin/env python3
"""Synthetic local PostgreSQL rollup benchmarks; never point at a hosted database.

Requires an explicitly named disposable Docker container running PostgreSQL18.
The setup is a minimal stand-in schema, not a production replay or migration test.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import pathlib
import re
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", choices=["setup", "query", "ingest"])
parser.add_argument(
    "--container", required=True, help="Existing disposable local Postgres container"
)
parser.add_argument("--database", default="tsw92_rollup_benchmark")
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument(
    "--source-root",
    type=pathlib.Path,
    default=pathlib.Path(__file__).resolve().parents[2],
)
parser.add_argument(
    "--restart-between-scenarios",
    action="store_true",
    help="Restart ONLY the named container; host cache remains warm",
)
parser.add_argument(
    "--incremental-jit-off",
    action="store_true",
    help="Use SET LOCAL jit=off for incremental queries only",
)
parser.add_argument("--key-counts", default="0,100,5000,10000")
parser.add_argument("--repetitions", type=int, default=5)
parser.add_argument("--combined-key-count", type=int, default=100)
args = parser.parse_args()
if not re.fullmatch(r"tsw92-[a-z0-9][a-z0-9-]*", args.container):
    parser.error("Container must have the explicit disposable tsw92- prefix")
if not re.fullmatch(r"tsw92_[a-z0-9_]+", args.database):
    parser.error("Database must have the explicit disposable tsw92_ prefix")
try:
    key_counts = [int(value) for value in args.key_counts.split(",")]
except ValueError:
    parser.error("Key counts must be comma-separated integers")
if not 1 <= len(key_counts) <= 10 or any(
    count < 0 or count > 10000 for count in key_counts
):
    parser.error("Supply one to ten key counts between 0 and 10000")
if len(set(key_counts)) != len(key_counts):
    parser.error("Key counts must be unique")
if not 1 <= args.repetitions <= 20:
    parser.error("Repetitions must be between 1 and 20")
if not 0 <= args.combined_key_count <= 10000:
    parser.error("Combined key count must be between 0 and 10000")
ROOT = args.source_root
CONTAINER = args.container
OUT = args.output
marker = {
    "setup": "setup.json",
    "query": "query-summary.json",
    "ingest": "trigger-summary.json",
}[args.command]
if (OUT / marker).exists():
    parser.error("This output already contains a completed run; choose a new directory")
docker_host = os.environ.get("DOCKER_HOST")
if not docker_host:
    context = subprocess.run(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
        text=True,
        capture_output=True,
        check=True,
    )
    docker_host = context.stdout.strip()
if not docker_host.startswith("unix://"):
    parser.error("Benchmarks require a local Docker Unix socket")
OUT.mkdir(parents=True, exist_ok=True)


def sql(source):
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            CONTAINER,
            "psql",
            "-U",
            "postgres",
            "-d",
            args.database,
            "-qAt",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        input=source,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return result.stdout


def setup():
    source = (
        ROOT
        / "services/wire-worker/Sources/WireWorkerCore/PostgresWireSignalRollupStore.swift"
    ).read_text()
    columns = re.search(
        r"INSERT INTO wire_signal_rollups_next\s*\((.*?)\)", source, re.S
    ).group(1)
    names = [v.strip() for v in columns.split(",")]
    rollup_columns = ", ".join(
        name
        + (
            " text PRIMARY KEY"
            if name == "canonical_key"
            else (
                " text"
                if name == "primary_community_key_hash"
                else (
                    " timestamptz"
                    if name in ["baseline_last_signal_at", "updated_at", "next_due_at"]
                    else " bigint NOT NULL DEFAULT 0"
                )
            )
        )
        for name in names
        if name != "next_due_at"
    )
    schema = """
CREATE TABLE wire_signal_events (
 id bigint GENERATED ALWAYS AS IDENTITY, canonical_key text NOT NULL,
 actor_key_hash text NOT NULL, community_key_hash text, signal_kind text NOT NULL,
 source_collection text NOT NULL, occurred_at timestamptz NOT NULL, expires_at timestamptz NOT NULL
) PARTITION BY RANGE(occurred_at);
DO $$ BEGIN
 FOR i IN 0..7 LOOP
 EXECUTE format('CREATE UNLOGGED TABLE wire_signal_events_%s PARTITION OF wire_signal_events FOR VALUES FROM (%L) TO (%L)',i, timestamptz '2026-09-06 00:00:00+00'+i*interval '1 day', timestamptz '2026-09-07 00:00:00+00'+i*interval '1 day');
 END LOOP;
END $$;
CREATE INDEX ON wire_signal_events(canonical_key,occurred_at DESC);
CREATE INDEX ON wire_signal_events(signal_kind,occurred_at DESC,canonical_key);
CREATE INDEX ON wire_signal_events(expires_at,occurred_at,id);
CREATE UNLOGGED TABLE wire_article_feedback(canonical_key text NOT NULL, actor_key_hash text NOT NULL, source_uri text NOT NULL,feedback_value text NOT NULL,occurred_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,PRIMARY KEY(canonical_key,actor_key_hash));
CREATE INDEX ON wire_article_feedback(expires_at,canonical_key);
""" + f"CREATE UNLOGGED TABLE wire_signal_rollups({rollup_columns});"
    sql(schema)
    sql(
        "BEGIN;"
        + (
            ROOT
            / "database/migrations/20260913020000_add_incremental_wire_rollup_work.sql"
        ).read_text()
        + "COMMIT;"
    )
    sql("""
INSERT INTO wire_signal_events(canonical_key,actor_key_hash,community_key_hash,signal_kind,source_collection,occurred_at,expires_at)
SELECT 'item-'||(g%10000)::text, 'actor-'||((g*17)%190000)::text,
 CASE WHEN g%7=0 THEN NULL ELSE 'community-'||(g%31)::text END,
 (ARRAY['share','like','repost','quote','recommendation','publication'])[1+g%6],
 CASE WHEN g%11=0 THEN 'network.cosmik.card' ELSE 'app.bsky.feed.post' END,
 timestamptz '2026-09-13 12:00:00+00' - (g%604799)*interval '1 second',
 timestamptz '2026-09-13 12:00:00+00' + (1+g%86400)*interval '1 second'
FROM generate_series(1,600000) g;
INSERT INTO wire_article_feedback
SELECT 'item-'||(g%10000)::text, 'actor-feedback-'||g::text,'at://feedback/'||g::text,
 CASE WHEN g%2=0 THEN 'good' ELSE 'not_good' END,
 timestamptz '2026-09-13 12:00:00+00' - (g%100000)*interval '1 second',
 timestamptz '2026-09-14 12:00:00+00'
FROM generate_series(1,20000) g;
VACUUM ANALYZE;
""")
    (OUT / "setup.json").write_text(
        sql(
            "SELECT json_build_object('events',(SELECT count(*) FROM wire_signal_events),'keys',(SELECT count(DISTINCT canonical_key) FROM wire_signal_events),'feedback',(SELECT count(*) FROM wire_article_feedback),'total_signal_bytes',(SELECT sum(pg_total_relation_size(relid)) FROM pg_partition_tree('wire_signal_events') WHERE isleaf),'postgres',version())"
        )
    )
    print((OUT / "setup.json").read_text())


def interval_seconds(expression):
    # Existing Swift expressions are signed integer constants or products.
    factors = expression.replace("_", "").split("*")
    result = 1
    for factor in factors:
        result *= int(factor.strip())
    return result


source = (
    ROOT
    / "services/wire-worker/Sources/WireWorkerCore/PostgresWireSignalRollupStore.swift"
).read_text()
raw = re.search(
    r'INSERT INTO wire_signal_rollups_next\s*\([^)]*\)\s*(.*?)\n        """',
    source,
    re.S,
).group(1)
extra_source = (
    ROOT
    / "services/wire-worker/Sources/WireWorkerCore/PostgresWireSignalRollupStore+Incremental.swift"
).read_text()
static_fragments = {}
for name in ["incrementalSignalPrefix", "incrementalFeedbackSuffix"]:
    match = re.search(r"static let " + name + r' = """(.*?)"""', extra_source, re.S)
    static_fragments[name] = match.group(1) if match else ""
asof = datetime.datetime(2026, 9, 13, 12, tzinfo=datetime.timezone.utc)


def timestamp(seconds=0):
    return (
        "timestamptz '" + (asof + datetime.timedelta(seconds=seconds)).isoformat() + "'"
    )


def query(incremental):
    q = re.sub(
        r"\\\(asOf.addingTimeInterval\(([-0-9_ *]+)\)\)",
        lambda m: timestamp(interval_seconds(m.group(1))),
        raw,
    )
    q = q.replace(r"\(asOf)", timestamp()).replace(
        r"\(incremental)", "true" if incremental else "false"
    )
    q = q.replace(
        r"\(unescaped: keyFilter)",
        (
            "AND canonical_key IN (SELECT canonical_key FROM wire_signal_rollup_keys)"
            if incremental
            else ""
        ),
    )
    for name, fragment in static_fragments.items():
        q = q.replace(
            "\\(unescaped: incremental ? Self." + name + ' : "")',
            fragment if incremental else "",
        )
    assert "\\(" not in q
    return q


def cpu():
    content = subprocess.run(
        ["docker", "exec", CONTAINER, "cat", "/sys/fs/cgroup/cpu.stat"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return int(dict(line.split() for line in content.splitlines())["usage_usec"])


def restart():
    subprocess.run(["docker", "restart", CONTAINER], check=True, capture_output=True)
    for _ in range(50):
        try:
            sql("SELECT 1")
            return
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("Postgres restart not ready")


def sample(count, number, cold=False):
    incr = count is not None
    setup = (
        "BEGIN; SET LOCAL jit=off;" if incr and args.incremental_jit_off else "BEGIN;"
    ) + "CREATE TEMP TABLE wire_signal_rollup_keys(canonical_key text PRIMARY KEY);"
    if count:
        setup += f"INSERT INTO wire_signal_rollup_keys SELECT 'item-'||g::text FROM generate_series(0,{count-1})g;"
    setup += "ANALYZE wire_signal_rollup_keys;"
    if cold:
        restart()
    before = cpu()
    response = sql(
        setup
        + "EXPLAIN (ANALYZE,BUFFERS,WAL,SETTINGS,TIMING OFF,FORMAT JSON) "
        + query(incr)
        + "; COMMIT;"
    )
    after = cpu()
    result = json.loads(response)[0]
    plan = result["Plan"]
    label = "full" if count is None else f"keys-{count}"
    (OUT / f"{label}-{number}.json").write_text(json.dumps(result, indent=2))
    row = {
        "scenario": label,
        "shared_buffer_state": (
            "restarted" if cold else ("initial" if number == 0 else "warm")
        ),
        "incremental_jit_off": incr and args.incremental_jit_off,
        "execution_ms": result["Execution Time"],
        "planning_ms": result["Planning Time"],
        "shared_hit_blocks": plan.get("Shared Hit Blocks", 0),
        "shared_read_blocks": plan.get("Shared Read Blocks", 0),
        "temp_read_blocks": plan.get("Temp Read Blocks", 0),
        "temp_written_blocks": plan.get("Temp Written Blocks", 0),
        "rows": plan["Actual Rows"],
        "container_cpu_ms": (after - before) / 1000,
    }
    print(json.dumps(row), flush=True)
    return row


def prepare(kind):
    source = (r"\set key random(0, 999)" if kind == "spread" else r"\set key 0") + """
INSERT INTO wire_signal_events(canonical_key,actor_key_hash,community_key_hash,signal_kind,source_collection,occurred_at,expires_at)
VALUES('bench-'||:key,'bench-actor-'||:client_id,'community-bench','share','app.bsky.feed.post',timestamptz '2026-09-13 12:00:00+00',timestamptz '2026-09-14 12:00:00+00');
"""
    subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            CONTAINER,
            "sh",
            "-c",
            "cat > /tmp/tsw92-trigger-work.sql",
        ],
        input=source,
        text=True,
        check=True,
    )


def run(kind, enabled, iteration, combined=False):
    sql(
        "SELECT wire_set_signal_rollup_tracking(false); DELETE FROM wire_signal_events WHERE canonical_key LIKE 'bench-%'; TRUNCATE wire_signal_rollup_dirty; VACUUM ANALYZE wire_signal_events;"
    )
    if enabled:
        sql("SELECT wire_set_signal_rollup_tracking(true);")
    tag = f"{time.time_ns()}-{kind}-{int(enabled)}-{iteration}-" + (
        "combined" if combined else "isolated"
    )
    beforelsn = sql("SELECT pg_current_wal_insert_lsn()").strip()
    beforecpu = cpu()
    cmd = [
        "docker",
        "exec",
        CONTAINER,
        "pgbench",
        "-U",
        "postgres",
        "-d",
        args.database,
        "-n",
        "-c",
        "8",
        "-j",
        "4",
        "-t",
        "1000",
        "-r",
        "-l",
        f"--log-prefix=/tmp/{tag}",
        "-f",
        "/tmp/tsw92-trigger-work.sql",
    ]
    started = time.monotonic()
    if combined:
        aggregate = (
            OUT / ("aggregate-incremental.sql" if enabled else "aggregate-full.sql")
        ).read_text()
        keysetup = (
            "BEGIN; SET LOCAL jit=off;"
            if enabled and args.incremental_jit_off
            else "BEGIN;"
        )
        keysetup += (
            "CREATE TEMP TABLE wire_signal_rollup_keys(canonical_key text PRIMARY KEY);"
        )
        keysetup += f"INSERT INTO wire_signal_rollup_keys SELECT 'item-'||g::text FROM generate_series(0,{args.combined_key_count-1})g; ANALYZE wire_signal_rollup_keys;"
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            queryfuture = pool.submit(
                sql,
                keysetup
                + "EXPLAIN(ANALYZE,BUFFERS,WAL,TIMING OFF,FORMAT JSON) "
                + aggregate
                + "; COMMIT;",
            )
            process = subprocess.run(cmd, text=True, capture_output=True)
            queryresult = json.loads(queryfuture.result())[0]
    else:
        process = subprocess.run(cmd, text=True, capture_output=True)
        queryresult = None
    elapsed = time.monotonic() - started
    aftercpu = cpu()
    if process.returncode:
        raise RuntimeError(process.stderr[-3000:])
    wal = int(sql(f"SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(),'{beforelsn}')"))
    logs = subprocess.run(
        ["docker", "exec", CONTAINER, "sh", "-c", f"cat /tmp/{tag}.*"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    latencies = sorted(
        float(line.split()[2]) / 1000 for line in logs.splitlines() if line.strip()
    )
    row = {
        "scenario": kind,
        "tracking": enabled,
        "iteration": iteration,
        "combined_aggregate_key_count": args.combined_key_count if combined else None,
        "incremental_jit_off": enabled and combined and args.incremental_jit_off,
        "transactions": len(latencies),
        "elapsed_seconds": elapsed,
        "median_ms": statistics.median(latencies),
        "p95_ms": latencies[int(0.95 * (len(latencies) - 1))],
        "p99_ms": latencies[int(0.99 * (len(latencies) - 1))],
        "container_cpu_ms": (aftercpu - beforecpu) / 1000,
        "wal_bytes": wal,
        "pgbench": process.stdout,
        "aggregate_ms": queryresult["Execution Time"] if queryresult else None,
    }
    (OUT / f"trigger-{tag}.json").write_text(json.dumps(row, indent=2))
    print(json.dumps({k: v for k, v in row.items() if k != "pgbench"}), flush=True)
    return row


if args.command == "setup":
    setup()
elif args.command == "query":
    rows = []
    (OUT / "aggregate-source.sha256").write_text(
        hashlib.sha256((source + "\n" + extra_source).encode()).hexdigest()
    )
    (OUT / "aggregate-full.sql").write_text(query(False))
    (OUT / "aggregate-incremental.sql").write_text(query(True))
    for count in [None] + key_counts:
        rows.append(sample(count, 0, cold=args.restart_between_scenarios))
        for number in range(1, args.repetitions + 1):
            rows.append(sample(count, number))
    (OUT / "query-summary.json").write_text(
        json.dumps(
            {
                "rows": rows,
                "limitations": [
                    "Synthetic600k events/10kkeys/20kfeedback, not representative replay",
                    "Cold means restarted PostgreSQL buffers; host filesystem cache stays warm",
                    "Container CPU includes psql and inspection overhead",
                    "EXPLAIN covers exact aggregate SELECT, not full maintenance transaction",
                ],
            },
            indent=2,
        )
    )
elif args.command == "ingest":
    for filename in ["aggregate-full.sql", "aggregate-incremental.sql"]:
        if not (OUT / filename).exists():
            parser.error("Run query into this output directory before ingest")
    rows = []
    for kind in ["spread", "hot"]:
        prepare(kind)
        for iteration in range(3):
            for enabled in [False, True]:
                rows.append(run(kind, enabled, iteration))
        for enabled in [False, True]:
            rows.append(run(kind, enabled, 3, combined=True))
    (OUT / "trigger-summary.json").write_text(json.dumps(rows, indent=2))
