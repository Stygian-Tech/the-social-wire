package appviewcore

import (
	"context"
	"database/sql"
)

func beginLegacyMutation(ctx context.Context, db *sql.DB, viewer string) (*sql.Tx, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO appview_pds_read_state_authority(viewer_did) VALUES($1) ON CONFLICT(viewer_did) DO NOTHING`, viewer); err != nil {
		tx.Rollback()
		return nil, err
	}
	var pds bool
	if err := tx.QueryRowContext(ctx, `SELECT manifest_cid IS NOT NULL FROM appview_pds_read_state_authority WHERE viewer_did=$1 FOR UPDATE`, viewer).Scan(&pds); err != nil {
		tx.Rollback()
		return nil, err
	}
	if pds {
		tx.Rollback()
		return nil, ErrPDSReadStateRequired
	}
	return tx, nil
}
