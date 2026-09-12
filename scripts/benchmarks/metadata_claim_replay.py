#!/usr/bin/env python3
"""Compare exact-order metadata claim plans on a disposable local PostgreSQL DB.

Requires psql and TSW_METADATA_REPLAY_DATABASE_URL. The URL must target a loopback
host and a database named tsw114_*. This replaces only tsw114_metadata_replay.
It does not run against Railway, reset counters, or alter application tables.
Example: python3 scripts/benchmarks/metadata_claim_replay.py --rows 100000
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from urllib.parse import urlsplit


AS_OF = "TIMESTAMPTZ '2026-09-12 00:00:00+00'"
SCHEMA = "tsw114_metadata_replay"
STATUSES = "('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')"


def validate_target(url):
    parsed = urlsplit(url)
    if (parsed.scheme not in ("postgres", "postgresql")
            or parsed.hostname not in ("127.0.0.1", "localhost", "::1")
            or not re.fullmatch(r"/tsw114_[a-z0-9_]+", parsed.path)
            or parsed.query or parsed.fragment or parsed.port == 0):
        raise ValueError("Use a disposable local tsw114_* database without URL options")


def due(alias):
    return f"""{alias}.status IN {STATUSES} AND (
      ({alias}.retry_after <= {AS_OF}
       AND ({alias}.fresh_until IS NULL OR {alias}.fresh_until <= {AS_OF}))
      OR ({alias}.source = 'open_graph' AND {alias}.status IN ('fresh', 'stale')
          AND {alias}.language_checked_at IS NULL))"""


def eligible(alias):
    return f"""{alias}.language_code = 'und' AND {alias}.eligible
      AND {alias}.expires_at > {AS_OF}
      AND {alias}.target_kind IN ('external_article', 'standard_site_document')
      AND {alias}.commercial_class <> 'probable_ad'
      AND {alias}.source_confidence >= 0.25"""


def selection(variant, limit):
    predicates = f"cache.language_checked_at IS NULL AND {due('cache')}"
    order = "item.last_signal_at DESC NULLS LAST, cache.retry_after, cache.canonical_key"
    if variant == "baseline":
        source = "wire_items item JOIN wire_link_metadata_cache cache USING (canonical_key)"
        predicates += f" AND {eligible('item')}"
        prefix = ""
    elif variant == "lateral":
        source = f"""wire_link_metadata_cache cache CROSS JOIN LATERAL (
          SELECT item.last_signal_at FROM wire_items item
          WHERE item.canonical_key = cache.canonical_key AND {eligible('item')}
          OFFSET 0) item"""
        prefix = ""
    elif variant == "materialized":
        # Keep eligibility on the lockable base alias too, so EvalPlanQual can
        # recheck a cache row changed concurrently after candidate materialization.
        prefix = f"""eligible_cache AS MATERIALIZED (
          SELECT cache.canonical_key FROM wire_link_metadata_cache cache
          WHERE {predicates}), """
        source = """eligible_cache candidate
          JOIN wire_items item USING (canonical_key)
          JOIN wire_link_metadata_cache cache USING (canonical_key)"""
        predicates += f" AND {eligible('item')}"
    else:
        raise ValueError(variant)
    return prefix, f"""SELECT cache.canonical_key FROM {source}
      WHERE {predicates} ORDER BY {order}
      FOR UPDATE OF cache SKIP LOCKED LIMIT {limit}"""


def claim(variant, limit, general=False):
    prefix, select = selection(variant, limit)
    if general:
        prefix = ""
        select = f"""SELECT cache.canonical_key FROM wire_link_metadata_cache cache
          WHERE {due('cache')}
          ORDER BY cache.language_checked_at NULLS FIRST, cache.retry_after, cache.canonical_key
          FOR UPDATE OF cache SKIP LOCKED LIMIT {limit}"""
    return f"""WITH {prefix}due AS ({select})
      UPDATE wire_link_metadata_cache cache
      SET status = 'fetching', retry_after = {AS_OF} + INTERVAL '5 minutes',
          fresh_until = CASE WHEN cache.language_checked_at IS NULL
            THEN LEAST(COALESCE(cache.fresh_until, {AS_OF}), {AS_OF})
            ELSE cache.fresh_until END,
          updated_at = {AS_OF}
      FROM due WHERE cache.canonical_key = due.canonical_key
      RETURNING cache.canonical_key"""


def setup_sql(rows, scenario):
    due_mod = {"sparse": 100, "dense": 2, "tied": 10, "null": 100}[scenario]
    signal = {
        "sparse": f"{AS_OF} - id * INTERVAL '1 second'",
        "dense": f"{AS_OF} - (id % 1000) * INTERVAL '1 second'",
        "tied": AS_OF,
        "null": f"CASE WHEN id % 1000 = 0 THEN {AS_OF} ELSE NULL END",
    }[scenario]
    return f"""
      DROP SCHEMA IF EXISTS {SCHEMA} CASCADE;
      CREATE SCHEMA {SCHEMA}; SET search_path = {SCHEMA};
      CREATE TABLE wire_items (
        canonical_key text PRIMARY KEY, language_code text, eligible boolean,
        expires_at timestamptz, target_kind text, commercial_class text,
        source_confidence double precision, last_signal_at timestamptz);
      CREATE TABLE wire_link_metadata_cache (
        canonical_key text PRIMARY KEY, canonical_url text, language_checked_at timestamptz,
        source text, status text, retry_after timestamptz, fresh_until timestamptz,
        updated_at timestamptz);
      INSERT INTO wire_items SELECT lpad(id::text, 10, '0'),
        CASE WHEN id % 7 = 0 THEN 'en' ELSE 'und' END, true,
        {AS_OF} + INTERVAL '1 day', 'external_article', 'editorial', 0.8, {signal}
        FROM generate_series(1, {rows}) id;
      INSERT INTO wire_link_metadata_cache SELECT lpad(id::text, 10, '0'),
        'https://example.test/' || id, NULL, 'fallback', 'pending',
        CASE WHEN id % {due_mod} = 0 THEN {AS_OF} - id * INTERVAL '1 second'
          ELSE {AS_OF} + INTERVAL '1 day' END, NULL, {AS_OF}
        FROM generate_series(1, {rows}) id;
      CREATE INDEX wire_items_unclassified_metadata_priority_idx ON wire_items
        (last_signal_at DESC NULLS LAST, canonical_key)
        WHERE language_code = 'und' AND eligible
          AND target_kind IN ('external_article', 'standard_site_document')
          AND commercial_class <> 'probable_ad' AND source_confidence >= 0.25;
      CREATE INDEX wire_link_metadata_cache_due_idx ON wire_link_metadata_cache
        (retry_after, fresh_until, canonical_key) WHERE status IN {STATUSES};
      CREATE INDEX wire_link_metadata_general_due_idx ON wire_link_metadata_cache
        (language_checked_at ASC NULLS FIRST, retry_after, canonical_key)
        WHERE status IN {STATUSES};
      CREATE INDEX wire_link_metadata_cache_language_backfill_idx ON wire_link_metadata_cache
        (canonical_key) WHERE source = 'open_graph'
          AND status IN ('fresh', 'stale') AND language_checked_at IS NULL;
      ANALYZE wire_items; ANALYZE wire_link_metadata_cache;
    """


def json_documents(raw):
    decoder = json.JSONDecoder()
    remaining = raw.strip()
    while remaining:
        value, end = decoder.raw_decode(remaining)
        yield value
        remaining = remaining[end:].lstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=100000)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--batches", type=int, nargs="+", default=[128, 8])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    url = os.environ.get("TSW_METADATA_REPLAY_DATABASE_URL", "")
    try:
        validate_target(url)
    except ValueError:
        parser.error("Set TSW_METADATA_REPLAY_DATABASE_URL to a disposable local tsw114_* database")
    if not 100000 <= args.rows <= 2000000 or not 1 <= args.repeats <= 10:
        parser.error("rows must be 100000...2000000 and repeats 1...10")
    if any(batch not in (8, 16, 32, 64, 128) for batch in args.batches):
        parser.error("batches must be one or more of 8,16,32,64,128")
    psql = shutil.which("psql") or "/opt/homebrew/opt/libpq/bin/psql"

    def run(sql):
        result = subprocess.run(
            [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", url],
            input=f"SET statement_timeout='120s'; SET search_path={SCHEMA};\n" + sql,
            text=True, capture_output=True, timeout=180)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    report = {"rows": args.rows, "postgres": run("SELECT version();").strip(),
              "samples": [], "lock_checks": []}
    for scenario in ("sparse", "dense", "tied", "null"):
        run(setup_sql(args.rows, scenario))
        # A separate transaction holds the leading priority candidate. All plans
        # must skip it, fill the same six-row claim, and retain exact tie ordering.
        prefix, select = selection("baseline", 6)
        candidates = json.loads(run(
            f"WITH {prefix}chosen AS ({select}) SELECT json_agg(canonical_key) FROM chosen;"))
        locked = candidates[0]
        holder = subprocess.Popen([psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", url],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        try:
            holder.stdin.write(f"SET search_path={SCHEMA}; SET statement_timeout='120s'; BEGIN;\n"
                               f"SELECT canonical_key FROM wire_link_metadata_cache "
                               f"WHERE canonical_key='{locked}' FOR UPDATE; SELECT 'LOCK_READY';\n")
            holder.stdin.flush()
            while True:
                line = holder.stdout.readline()
                if line.strip() == "LOCK_READY":
                    break
                if not line:
                    raise RuntimeError("Lock fixture exited before acquiring the row")
            expected_locked = None
            for variant in ("baseline", "lateral", "materialized"):
                output = run(f"BEGIN; {claim(variant, 6)}; "
                             "SELECT json_agg(canonical_key ORDER BY canonical_key) "
                             "FROM wire_link_metadata_cache WHERE status='fetching'; ROLLBACK;")
                keys = json.loads(output.splitlines()[-1])
                if expected_locked is None:
                    expected_locked = keys
                if len(keys) != 6 or locked in keys or keys != expected_locked:
                    raise AssertionError(f"{scenario} {variant} changed locked-row claim set")
            report["lock_checks"].append({"scenario": scenario, "claimed": 6, "variants_equal": True})
        finally:
            if holder.poll() is None:
                holder.stdin.write("ROLLBACK;\n")
                holder.stdin.flush()
                holder.communicate(timeout=10)
        expected = {}
        for repeat in range(args.repeats):
            variants = ["baseline", "lateral", "materialized"]
            variants = variants[repeat % 3:] + variants[:repeat % 3]
            for batch in args.batches:
                for variant in variants:
                    statements = ["BEGIN;"]
                    for _ in range(128 // batch):
                        priority = batch * 3 // 4
                        for query in (claim(variant, priority), claim(variant, batch - priority, True)):
                            statements.append("EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON) " + query + ";")
                    statements += ["SELECT json_agg(canonical_key ORDER BY canonical_key) "
                                   "FROM wire_link_metadata_cache WHERE status='fetching';", "ROLLBACK;"]
                    started = time.monotonic()
                    docs = list(json_documents(run("\n".join(statements))))
                    keys = docs.pop()
                    expected.setdefault(batch, keys)
                    if keys != expected[batch]:
                        raise AssertionError(f"{scenario} batch={batch} {variant} changed exact claim set")
                    totals = {"execution_ms": 0, "shared_hits": 0, "shared_reads": 0,
                              "temp_reads": 0, "temp_writes": 0, "wal_bytes": 0}
                    nodes = set()

                    def inspect(node):
                        nodes.add(node["Node Type"])
                        for child in node.get("Plans", []):
                            inspect(child)

                    for document in docs:
                        plan = document[0]
                        inspect(plan["Plan"])
                        totals["execution_ms"] += plan["Execution Time"]
                        for key, field in (("shared_hits", "Shared Hit Blocks"),
                                           ("shared_reads", "Shared Read Blocks"),
                                           ("temp_reads", "Temp Read Blocks"),
                                           ("temp_writes", "Temp Written Blocks"),
                                           ("wal_bytes", "WAL Bytes")):
                            totals[key] += plan["Plan"].get(field, 0)
                    sample = dict(scenario=scenario, repeat=repeat, batch=batch, variant=variant,
                                  claimed=len(keys), plans=sorted(nodes), wall_seconds=time.monotonic()-started,
                                  **totals)
                    report["samples"].append(sample)
                    print(json.dumps(sample), flush=True)
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
