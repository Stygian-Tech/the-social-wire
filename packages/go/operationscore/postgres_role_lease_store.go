package operationscore

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// PostgresRoleLeaseStore uses the existing operations_role_leases schema. Control
// connections must be budgeted separately from workload/publication connections.
type PostgresRoleLeaseStore struct {
	DB          *sql.DB
	Environment string
}

func beginControl(ctx context.Context, db *sql.DB) (*sql.Tx, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	for _, query := range []string{"SET LOCAL statement_timeout = '2s'", "SET LOCAL lock_timeout = '500ms'"} {
		if _, err = tx.ExecContext(ctx, query); err != nil {
			_ = tx.Rollback()
			return nil, err
		}
	}
	return tx, nil
}
func scanLease(row *sql.Row) (FencedRoleLease, error) {
	var v FencedRoleLease
	err := row.Scan(&v.Environment, &v.Role, &v.OwnerID, &v.FencingToken, &v.AcquiredAt, &v.ExpiresAt, &v.UpdatedAt)
	return v, err
}

const returningLease = " RETURNING lease.environment,lease.role,lease.owner_id,lease.fencing_token,lease.acquired_at,lease.lease_expires_at,lease.updated_at"

func (s *PostgresRoleLeaseStore) Acquire(ctx context.Context, role, owner string, duration time.Duration) (*FencedRoleLease, error) {
	if err := ValidateRoleIdentity(role, owner); err != nil {
		return nil, err
	}
	if duration <= 0 || s.Environment == "" {
		return nil, ErrInvalidProgress
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := beginControl(ctx, s.DB)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `WITH instant AS (SELECT clock_timestamp() AS now)
 INSERT INTO operations_role_leases(environment,role,owner_id,fencing_token,acquired_at,lease_expires_at,released_at,updated_at)
 SELECT $1,$2,$3,1,instant.now,instant.now+$4*INTERVAL '1 second',NULL,instant.now FROM instant
 ON CONFLICT(environment,role) DO NOTHING`, s.Environment, role, owner, duration.Seconds())
	if err != nil {
		return nil, err
	}
	var token int64
	err = tx.QueryRowContext(ctx, `SELECT fencing_token FROM operations_role_leases
 WHERE environment=$1 AND role=$2 AND (released_at IS NOT NULL OR lease_expires_at<=clock_timestamp() OR owner_id=$3)
 FOR UPDATE SKIP LOCKED`, s.Environment, role, owner).Scan(&token)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, tx.Commit()
	}
	if err != nil {
		return nil, err
	}
	v, err := scanLease(tx.QueryRowContext(ctx, `WITH instant AS (SELECT clock_timestamp() AS now)
 UPDATE operations_role_leases AS lease SET owner_id=$3,
 fencing_token=CASE WHEN lease.owner_id=$3 AND lease.released_at IS NULL AND lease.lease_expires_at>instant.now THEN lease.fencing_token ELSE lease.fencing_token+1 END,
 acquired_at=CASE WHEN lease.owner_id=$3 AND lease.released_at IS NULL AND lease.lease_expires_at>instant.now THEN lease.acquired_at ELSE instant.now END,
 lease_expires_at=instant.now+$4*INTERVAL '1 second',released_at=NULL,updated_at=instant.now FROM instant
 WHERE lease.environment=$1 AND lease.role=$2 AND (lease.released_at IS NOT NULL OR lease.lease_expires_at<=instant.now OR lease.owner_id=$3)`+returningLease, s.Environment, role, owner, duration.Seconds()))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, tx.Commit()
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &v, nil
}

// LockRoleLeaseFence must run in the transaction publishing the protected work.
// Check database time AFTER acquiring the lock, matching Swift's fence protocol.
func LockRoleLeaseFence(ctx context.Context, tx *sql.Tx, a RoleLeaseAuthority, renewing bool) error {
	if err := ValidateRoleIdentity(a.Role, a.OwnerID); err != nil {
		return err
	}
	if a.Environment == "" || a.FencingToken <= 0 {
		return ErrInvalidProgress
	}
	for _, q := range []string{"SET LOCAL statement_timeout = '2s'", "SET LOCAL lock_timeout = '500ms'"} {
		if _, err := tx.ExecContext(ctx, q); err != nil {
			return err
		}
	}
	lock := "FOR KEY SHARE"
	if renewing {
		lock = "FOR NO KEY UPDATE"
	}
	var token int64
	if err := tx.QueryRowContext(ctx, `SELECT fencing_token FROM operations_role_leases WHERE environment=$1 AND role=$2 `+lock, a.Environment, a.Role).Scan(&token); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseConflict
		}
		return err
	}
	var valid bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM operations_role_leases WHERE environment=$1 AND role=$2 AND owner_id=$3 AND fencing_token=$4 AND released_at IS NULL AND lease_expires_at>clock_timestamp())`, a.Environment, a.Role, a.OwnerID, a.FencingToken).Scan(&valid); err != nil {
		return err
	}
	if !valid {
		return ErrLeaseConflict
	}
	return nil
}
func (s *PostgresRoleLeaseStore) Renew(ctx context.Context, a RoleLeaseAuthority, duration time.Duration) (FencedRoleLease, error) {
	if duration <= 0 || a.Environment != s.Environment {
		return FencedRoleLease{}, ErrInvalidProgress
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := beginControl(ctx, s.DB)
	if err != nil {
		return FencedRoleLease{}, err
	}
	defer tx.Rollback()
	if err := LockRoleLeaseFence(ctx, tx, a, true); err != nil {
		return FencedRoleLease{}, err
	}
	v, err := scanLease(tx.QueryRowContext(ctx, `WITH instant AS (SELECT clock_timestamp() AS now)
 UPDATE operations_role_leases AS lease SET lease_expires_at=instant.now+$5*INTERVAL '1 second',updated_at=instant.now FROM instant
 WHERE lease.environment=$1 AND lease.role=$2 AND lease.owner_id=$3 AND lease.fencing_token=$4 AND lease.released_at IS NULL AND lease.lease_expires_at>instant.now`+returningLease, a.Environment, a.Role, a.OwnerID, a.FencingToken, duration.Seconds()))
	if errors.Is(err, sql.ErrNoRows) {
		return FencedRoleLease{}, ErrLeaseConflict
	}
	if err != nil {
		return FencedRoleLease{}, err
	}
	return v, tx.Commit()
}
func (s *PostgresRoleLeaseStore) Release(ctx context.Context, a RoleLeaseAuthority) error {
	if err := ValidateRoleIdentity(a.Role, a.OwnerID); err != nil {
		return err
	}
	if a.Environment != s.Environment {
		return ErrInvalidProgress
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := beginControl(ctx, s.DB)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var token int64
	if err := tx.QueryRowContext(ctx, `SELECT fencing_token FROM operations_role_leases WHERE environment=$1 AND role=$2 AND owner_id=$3 AND fencing_token=$4 AND released_at IS NULL FOR UPDATE`, a.Environment, a.Role, a.OwnerID, a.FencingToken).Scan(&token); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseConflict
		}
		return err
	}
	result, err := tx.ExecContext(ctx, `UPDATE operations_role_leases SET released_at=clock_timestamp(),updated_at=clock_timestamp() WHERE environment=$1 AND role=$2 AND owner_id=$3 AND fencing_token=$4 AND released_at IS NULL`, a.Environment, a.Role, a.OwnerID, a.FencingToken)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrLeaseConflict
	}
	return tx.Commit()
}
func (s *PostgresRoleLeaseStore) Validate(ctx context.Context, a RoleLeaseAuthority) error {
	if a.Environment != s.Environment {
		return ErrInvalidProgress
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := beginControl(ctx, s.DB)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := LockRoleLeaseFence(ctx, tx, a, false); err != nil {
		return err
	}
	return tx.Commit()
}
