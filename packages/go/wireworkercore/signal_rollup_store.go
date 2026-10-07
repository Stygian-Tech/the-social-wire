package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type PostgresSignalRollupStore struct {
	DB                 *sql.DB
	IncrementalEnabled bool
}

func postgresState(err error, state string) bool {
	var postgres *pgconn.PgError
	return errors.As(err, &postgres) && postgres.Code == state
}

// Refresh publishes one complete rolling-window snapshot. Only a serialization
// conflict with a confirmed rollback may retry; commit uncertainty never retries.
func (s PostgresSignalRollupStore) Refresh(ctx context.Context, at time.Time) error {
	for attempt := 0; attempt < 3; attempt++ {
		retry, err := s.refreshOnce(ctx, at)
		if err == nil {
			return nil
		}
		if !retry || attempt == 2 {
			return err
		}
		if err = waitContext(ctx, time.Duration(50*(attempt+1))*time.Millisecond); err != nil {
			return err
		}
	}
	return errors.New("unreachable rollup retry state")
}
func (s PostgresSignalRollupStore) refreshOnce(ctx context.Context, at time.Time) (retry bool, refreshError error) {
	options := &sql.TxOptions{}
	if s.IncrementalEnabled {
		options.Isolation = sql.LevelRepeatableRead
	}
	tx, err := s.DB.BeginTx(ctx, options)
	if err != nil {
		return false, err
	}
	committing := false
	defer func() {
		rollback := tx.Rollback()
		retry = !committing && refreshError != nil && rollback == nil && postgresState(refreshError, "40001")
		if rollback != nil && rollback != sql.ErrTxDone {
			refreshError = errors.Join(refreshError, rollback)
			retry = false
		}
	}()
	exec := func(query string, args ...any) error { _, err := tx.ExecContext(ctx, query, args...); return err }
	if s.IncrementalEnabled {
		if err = exec(`LOCK TABLE ONLY wire_signal_events IN SHARE UPDATE EXCLUSIVE MODE NOWAIT`); err != nil {
			return false, err
		}
	}
	if err = exec(`SELECT pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint)`); err != nil {
		return false, err
	}
	incremental := false
	if s.IncrementalEnabled {
		if err = tx.QueryRowContext(ctx, `SELECT tracking_enabled FROM wire_signal_rollup_control WHERE singleton`).Scan(&incremental); err != nil {
			return false, err
		}
	}
	if incremental {
		for _, query := range []string{`SET LOCAL jit=off`, rollupLockRelationsSQL, rollupClaimedSQL, rollupKeysTableSQL} {
			if err = exec(query); err != nil {
				return false, err
			}
		}
		if err = exec(rollupRefreshStateSQL, at); err != nil {
			return false, err
		}
		if err = exec(rollupSelectKeysSQL, at, at.Add(-7*24*time.Hour)); err != nil {
			return false, err
		}
		if err = exec(`CREATE TEMP TABLE wire_signal_rollup_batch(canonical_key text PRIMARY KEY)ON COMMIT DROP`); err != nil {
			return false, err
		}
		if err = exec(`ANALYZE wire_signal_rollup_keys`); err != nil {
			return false, err
		}
	}
	if err = exec(`CREATE TEMP TABLE wire_signal_rollups_next(LIKE wire_signal_rollups INCLUDING DEFAULTS,next_due_at timestamptz)ON COMMIT DROP`); err != nil {
		return false, err
	}
	stage := rollupStageFullSQL
	if incremental {
		stage = rollupStageIncrementalSQL
		var after *string
		for {
			if err = ctx.Err(); err != nil {
				return false, err
			}
			if err = exec(`TRUNCATE wire_signal_rollup_batch`); err != nil {
				return false, err
			}
			if err = exec(rollupNextBatchSQL, after); err != nil {
				return false, err
			}
			if err = exec(`ANALYZE wire_signal_rollup_batch`); err != nil {
				return false, err
			}
			var last sql.NullString
			if err = tx.QueryRowContext(ctx, `SELECT max(canonical_key) FROM wire_signal_rollup_batch`).Scan(&last); err != nil {
				return false, err
			}
			if !last.Valid {
				break
			}
			if err = exec(stage, at, at.Add(-time.Hour), at.Add(-24*time.Hour), at.Add(-7*24*time.Hour)); err != nil {
				return false, err
			}
			next := last.String
			after = &next
		}
	} else {
		if err = exec(stage, at, at.Add(-time.Hour), at.Add(-24*time.Hour), at.Add(-7*24*time.Hour)); err != nil {
			return false, err
		}
	}
	for _, query := range []string{`ALTER TABLE wire_signal_rollups_next ADD PRIMARY KEY(canonical_key)`, `ANALYZE wire_signal_rollups_next(canonical_key)`} {
		if err = exec(query); err != nil {
			return false, err
		}
	}
	var workMemory string
	if err = tx.QueryRowContext(ctx, `SELECT current_setting('work_mem')`).Scan(&workMemory); err != nil {
		return false, err
	}
	if err = exec(`SELECT set_config('work_mem','64MB',true)`); err != nil {
		return false, err
	}
	deleteSQL := rollupDeleteFullSQL
	if incremental {
		deleteSQL = rollupDeleteIncrementalSQL
	}
	for _, query := range []string{rollupUpdateSQL, rollupInsertSQL, deleteSQL} {
		if err = exec(query); err != nil {
			return false, err
		}
	}
	if err = exec(`SELECT set_config('work_mem',$1,true)`, workMemory); err != nil {
		return false, err
	}
	if incremental {
		var unchanged bool
		if err = tx.QueryRowContext(ctx, `SELECT signature=wire_signal_rollup_relation_signature() FROM wire_signal_rollup_refresh_state`).Scan(&unchanged); err != nil {
			return false, err
		}
		if !unchanged {
			return false, errors.New("Wire rollup source relations changed")
		}
		for _, query := range []string{rollupScheduleSQL, rollupDeleteScheduleSQL, `SAVEPOINT wire_rollup_acknowledgment`} {
			if err = exec(query); err != nil {
				return false, err
			}
		}
		if err = exec(rollupAcknowledgeSQL); err != nil {
			if !postgresState(err, "40001") {
				return false, err
			}
			if err = exec(`ROLLBACK TO SAVEPOINT wire_rollup_acknowledgment`); err != nil {
				return false, err
			}
		}
		if err = exec(`RELEASE SAVEPOINT wire_rollup_acknowledgment`); err != nil {
			return false, err
		}
		if err = exec(rollupControlSQL, at); err != nil {
			return false, err
		}
	} else {
		if err = exec(`UPDATE wire_signal_rollup_control SET last_as_of=NULL WHERE singleton AND last_as_of IS NOT NULL`); err != nil {
			return false, err
		}
	}
	committing = true
	err = tx.Commit()
	return false, err
}
