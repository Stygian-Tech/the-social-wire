"""Read actual Go rollup constants and reject drift in production bind construction."""
import datetime
import re

NAMES = ('rollupUpdateSQL','rollupInsertSQL','rollupDeleteFullSQL','rollupDeleteIncrementalSQL',
 'rollupStageFullSQL','rollupStageIncrementalSQL','rollupLockRelationsSQL','rollupRefreshStateSQL',
 'rollupClaimedSQL','rollupKeysTableSQL','rollupSelectKeysSQL','rollupNextBatchSQL',
 'rollupScheduleSQL','rollupDeleteScheduleSQL','rollupAcknowledgeSQL','rollupControlSQL')


def load(root):
    source = (root / 'packages/go/wireworkercore/signal_rollup_sql.go').read_text()
    pairs = re.findall(r'const\s+(rollup\w+SQL)\s*=\s*`([^`]*)`', source)
    statements = dict(pairs)
    if tuple(name for name, _ in pairs) != NAMES:
        raise ValueError('Go rollup SQL constants missing, duplicated, or reordered')
    runtime = (root / 'packages/go/wireworkercore/signal_rollup_store.go').read_text()
    for expression in ('exec(stage, at, at.Add(-time.Hour), at.Add(-24*time.Hour), at.Add(-7*24*time.Hour))',
        'exec(rollupRefreshStateSQL, at)', 'exec(rollupSelectKeysSQL, at, at.Add(-7*24*time.Hour))',
        'exec(rollupNextBatchSQL, after)', 'exec(rollupControlSQL, at)', 'SAVEPOINT wire_rollup_acknowledgment'):
        if expression not in runtime:
            raise ValueError('Go rollup bind or acknowledgment contract changed: ' + expression)
    if runtime.count('exec(stage, at, at.Add(-time.Hour), at.Add(-24*time.Hour), at.Add(-7*24*time.Hour))') != 2:
        raise ValueError('Full and incremental Go stage bindings changed')
    return statements


def timestamp(at, seconds=0):
    return "timestamptz '" + (at + datetime.timedelta(seconds=seconds)).isoformat() + "'"


def render(source, values):
    placeholders = {int(n) for n in re.findall(r'\$(\d+)', source)}
    if placeholders and placeholders != set(range(1, len(values) + 1)):
        raise ValueError('Go rollup placeholders differ from supplied runtime bindings')
    return re.sub(r'\$(\d+)', lambda m: values[int(m.group(1)) - 1], source)


def stage(statements, incremental, at):
    return render(statements['rollupStageIncrementalSQL' if incremental else 'rollupStageFullSQL'],
      [timestamp(at, offset) for offset in (0, -3600, -86400, -604800)])


def aggregate(statements, incremental, at):
    query = stage(statements, incremental, at)
    query = re.sub(r'^INSERT INTO wire_signal_rollups_next\s*\([^)]*\)\s*', '', query)
    if incremental:
        query = query.replace('wire_signal_rollup_batch', 'wire_signal_rollup_keys')
    return query


def refresh(statements, incremental, at):
    q = ['BEGIN;']
    if incremental:
        q += ['SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;',
          'LOCK TABLE ONLY wire_signal_events IN SHARE UPDATE EXCLUSIVE MODE NOWAIT;']
    q += ["SELECT pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint);"]
    def append(name, values=()): q.append(render(statements[name], values) + ';')
    if incremental:
        q += ['SET LOCAL jit=off;']
        append('rollupLockRelationsSQL')
        append('rollupClaimedSQL')
        append('rollupKeysTableSQL')
        append('rollupRefreshStateSQL', [timestamp(at)])
        append('rollupSelectKeysSQL', [timestamp(at), timestamp(at, -604800)])
        q += ['CREATE TEMP TABLE wire_signal_rollup_batch(canonical_key text PRIMARY KEY) ON COMMIT DROP;',
          'ANALYZE wire_signal_rollup_keys;']
    q += ['CREATE TEMP TABLE wire_signal_rollups_next(LIKE wire_signal_rollups INCLUDING DEFAULTS,next_due_at timestamptz) ON COMMIT DROP;']
    if incremental:
        batch = render(statements['rollupNextBatchSQL'], ['after_key'])
        q += ["DO $batch$ DECLARE after_key text; last_key text; BEGIN LOOP\n"
          + 'TRUNCATE wire_signal_rollup_batch;\n' + batch + ';\nANALYZE wire_signal_rollup_batch;\n'
          + 'SELECT max(canonical_key) INTO last_key FROM wire_signal_rollup_batch; EXIT WHEN last_key IS NULL;\n'
          + stage(statements, True, at) + '; after_key := last_key; END LOOP; END $batch$;']
    else:
        q += [stage(statements, False, at) + ';']
    q += ["ALTER TABLE wire_signal_rollups_next ADD PRIMARY KEY(canonical_key); ANALYZE wire_signal_rollups_next(canonical_key);",
      "SELECT set_config('tsw_benchmark.saved_work_mem',current_setting('work_mem'),true); SET LOCAL work_mem='64MB';"]
    for name in ('rollupUpdateSQL', 'rollupInsertSQL', 'rollupDeleteIncrementalSQL' if incremental else 'rollupDeleteFullSQL'): append(name)
    q += ["SELECT set_config('work_mem',current_setting('tsw_benchmark.saved_work_mem'),true);"]
    if incremental:
        q += ["DO $identity$ BEGIN IF EXISTS(SELECT 1 FROM wire_signal_rollup_refresh_state WHERE signature IS DISTINCT FROM wire_signal_rollup_relation_signature()) THEN RAISE EXCEPTION 'source relations changed during refresh'; END IF; END $identity$;"]
        append('rollupScheduleSQL'); append('rollupDeleteScheduleSQL')
        # PL/pgSQL exception blocks reproduce the production acknowledgment savepoint.
        q += ['DO $ack$ BEGIN ' + statements['rollupAcknowledgeSQL'] + "; EXCEPTION WHEN serialization_failure THEN RAISE NOTICE 'acknowledgment deferred'; END $ack$;"]
        append('rollupControlSQL', [timestamp(at)])
    else:
        q += ['UPDATE wire_signal_rollup_control SET last_as_of=NULL WHERE singleton AND last_as_of IS NOT NULL;']
    return '\n'.join(q) + '\nCOMMIT;'
