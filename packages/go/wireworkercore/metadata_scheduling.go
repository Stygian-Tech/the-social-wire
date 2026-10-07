package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

func (s *MetadataStore) schedulingReady(ctx context.Context, tx *sql.Tx) (bool, error) {
	var ready bool
	err := tx.QueryRowContext(ctx, metadataSchedulingReadySQL).Scan(&ready)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return ready, err
}
func (s *MetadataStore) MaintainScheduling(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	if authority == nil {
		return ErrMissingAuthority
	}
	if _, err := s.DB.ExecContext(ctx, `SELECT wire_metadata_schedule_reset_after_restart()`); err != nil {
		return err
	}
	for _, query := range []string{metadataSchedulingItemBackfillSQL, metadataSchedulingCacheBackfillSQL} {
		tx, err := s.DB.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `SET LOCAL lock_timeout='500ms'`); err == nil {
			_, err = tx.ExecContext(ctx, `SET LOCAL statement_timeout='5s'`)
		}
		if err == nil {
			_, err = tx.ExecContext(ctx, query, 500)
		}
		if err == nil {
			err = operationscore.LockRoleLeaseFence(ctx, tx, *authority, false)
		}
		if err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	if err := s.validateScheduling(ctx, authority, at); err != nil {
		return err
	}
	_, err := s.DB.ExecContext(ctx, metadataSchedulingCleanupSQL, 500)
	return err
}
func (s *MetadataStore) validateScheduling(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='30s'`); err != nil {
		return err
	}
	var control bool
	err = tx.QueryRowContext(ctx, metadataSchedulingControlSQL).Scan(&control)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	var mismatches int64
	if err := tx.QueryRowContext(ctx, metadataSchedulingParitySQL).Scan(&mismatches); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, metadataSchedulingValidateSQL, mismatches == 0, at, mismatches); err != nil {
		return err
	}
	if err := operationscore.LockRoleLeaseFence(ctx, tx, *authority, false); err != nil {
		return err
	}
	return tx.Commit()
}
