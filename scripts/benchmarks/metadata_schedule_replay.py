#!/usr/bin/env python3
"""Replay the real scheduling migration, owned-field triggers, and mixed writes locally.

Requires TSW_METADATA_REPLAY_DATABASE_URL pointing at an explicitly disposable
loopback tsw114_* database. Replaces only tsw114_schedule_replay schema. Includes
trigger execution in timing by making deferred constraints immediate for replay.
No hosted access. Whole-cluster WAL deltas require an otherwise idle database
cluster; never treat concurrent-test WAL as an acceptance result.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

import metadata_claim_replay as base


ITEM = ['language_code', 'eligible', 'expires_at', 'target_kind', 'commercial_class', 'source_confidence', 'last_signal_at']
CACHE = ['language_checked_at', 'source', 'status', 'retry_after', 'fresh_until']


def schedule_claim(limit):
    query = base.claim('baseline', limit)
    query = query.replace('wire_items item JOIN', 'wire_metadata_priority_work item JOIN')
    query = query.replace('WHERE cache.language_checked_at', 'WHERE item.item_present AND item.cache_present AND item.language_checked_at IS NULL AND cache.language_checked_at')
    query = query.replace('WHERE item.item_present',
                          f"WHERE EXISTS (SELECT 1 FROM wire_items authoritative WHERE authoritative.canonical_key=item.canonical_key AND {base.eligible('authoritative')}) AND item.item_present")
    query = query.replace('ORDER BY item.last_signal_at DESC NULLS LAST, cache.retry_after, cache.canonical_key',
                          'ORDER BY item.last_signal_at DESC NULLS LAST, item.retry_after, item.canonical_key')
    query = query.replace(' ORDER BY item.last_signal_at', f" AND {base.due('item')} ORDER BY item.last_signal_at")
    return query


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rows', type=int, default=100000)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 100000 <= args.rows <= 2000000 or not 1 <= args.repeats <= 10:
        parser.error('rows must be 100000...2000000; repeats 1...10')
    url = os.environ.get('TSW_METADATA_REPLAY_DATABASE_URL', '')
    try:
        base.validate_target(url)
    except ValueError:
        parser.error('Set an explicit disposable local tsw114_* database URL')
    psql = shutil.which('psql') or '/opt/homebrew/opt/libpq/bin/psql'
    base.SCHEMA = 'tsw114_schedule_replay'

    def run(sql):
        result = subprocess.run([psql, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', url],
                                input=f"SET search_path={base.SCHEMA}; SET statement_timeout='120s';\n" + sql,
                                text=True, capture_output=True, timeout=300)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    migration = (Path(__file__).resolve().parents[2] / 'database/migrations/20260912010000_add_wire_metadata_schedule.sql').read_text()
    index_migration = (Path(__file__).resolve().parents[2] / 'database/migrations/20260912010100_index_wire_metadata_priority_work.sql').read_text()
    # This runner isolates its schema; production Migrator uses public.
    index_migration = index_migration.replace('public.wire_metadata_priority_work_order_idx', base.SCHEMA + '.wire_metadata_priority_work_order_idx')
    report = {'rows': args.rows, 'samples': [], 'truncate_checks': [],
              'wal_scope': 'whole cluster; idle cluster required for acceptance'}
    for scenario in ('sparse', 'dense', 'tied', 'null'):
        run(base.setup_sql(args.rows, scenario))
        run('BEGIN;\n' + migration + '\nCOMMIT;')
        run(index_migration)
        expected = None
        for repeat in range(args.repeats):
            for variant in (('baseline', 'schedule') if repeat % 2 == 0 else ('schedule', 'baseline')):
                run(f"SELECT wire_metadata_schedule_set_tracking({'true' if variant == 'schedule' else 'false'});")
                if variant == 'schedule':
                    run(f"""INSERT INTO wire_metadata_priority_work
                      (canonical_key,item_present,cache_present,{','.join(ITEM+CACHE)})
                      SELECT item.canonical_key,true,true,{','.join('item.'+c for c in ITEM)},{','.join('cache.'+c for c in CACHE)}
                      FROM wire_items item JOIN wire_link_metadata_cache cache USING(canonical_key);
                      ANALYZE wire_metadata_priority_work;""")
                claims = [schedule_claim(96) if variant == 'schedule' else base.claim('baseline', 96),
                          base.claim('baseline', 32, general=True)]
                writes = [
                    f"UPDATE wire_items SET last_signal_at={base.AS_OF}+INTERVAL '1 second' WHERE canonical_key <= '0000001000'",
                    "UPDATE wire_link_metadata_cache SET retry_after=retry_after+INTERVAL '1 second' WHERE canonical_key <= '0000001000'",
                    "UPDATE wire_link_metadata_cache SET canonical_url=canonical_url WHERE canonical_key <= '0000001000'",
                ]
                sql = ['BEGIN;', 'SET CONSTRAINTS ALL IMMEDIATE;', "SELECT to_json(pg_current_wal_insert_lsn()::text);"]
                for query in writes + claims:
                    sql.append('EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON) ' + query + ';')
                sql += ["SELECT json_agg(canonical_key ORDER BY canonical_key) FROM wire_link_metadata_cache WHERE status='fetching';",
                        "SELECT to_json(pg_current_wal_insert_lsn()::text);", 'ROLLBACK;']
                docs = list(base.json_documents(run('\n'.join(sql))))
                start, finish = docs.pop(0), docs.pop()
                keys = docs.pop()
                if expected is None:
                    expected = keys
                if keys != expected:
                    raise AssertionError(f'{scenario} {variant} changed the exact claim set')
                def lsn(value):
                    high, low = value.split('/')
                    return (int(high, 16) << 32) + int(low, 16)
                sample = {'scenario': scenario, 'repeat': repeat, 'variant': variant,
                          'claimed': len(keys), 'cluster_wal_bytes': lsn(finish)-lsn(start),
                          'mixed_execution_ms': sum(d[0]['Execution Time'] for d in docs),
                          'claim_execution_ms': sum(d[0]['Execution Time'] for d in docs[-2:]),
                          'priority_shared_accesses': sum(docs[-2][0]['Plan'].get(k, 0) for k in ('Shared Hit Blocks', 'Shared Read Blocks')),
                          'trigger_ms': sum(t['Time'] for d in docs for t in d[0].get('Triggers', []))}
                report['samples'].append(sample)
                print(json.dumps(sample), flush=True)
        # Source TRUNCATE bypasses row triggers; its dedicated statement trigger
        # must invalidate coverage. This touches only this disposable schema and
        # rolls back the truncate, preserving the fixture for inspection.
        output = run("""BEGIN;
          SELECT wire_metadata_schedule_set_tracking(true);
          UPDATE wire_metadata_schedule_control SET read_ready=true,
            validated_postmaster_started_at=pg_postmaster_start_time();
          TRUNCATE wire_items;
          SELECT json_build_object('not_ready', NOT read_ready,
            'invalid_epoch', tracking_postmaster_started_at IS NULL)
          FROM wire_metadata_schedule_control; ROLLBACK;""")
        check = json.loads(output.strip())
        if check != {'not_ready': True, 'invalid_epoch': True}:
            raise AssertionError('Source truncate failed to invalidate scheduling coverage')
        report['truncate_checks'].append({'scenario': scenario, **check})
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
