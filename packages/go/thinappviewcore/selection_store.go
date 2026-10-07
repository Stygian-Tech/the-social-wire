package thinappviewcore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

type SelectionStore struct{ DB *sql.DB }

func (s SelectionStore) Apply(ctx context.Context, mutation SelectionMutation) error {
	topic := mutation.Topic
	field := "kind"
	lock := 91827
	if topic == "sports" {
		field = "action"
		lock = 91828
	} else if topic != "finance" {
		return errors.New("invalid selection topic")
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,$2))", mutation.ViewerDID, lock); err != nil {
		return err
	}
	statement := fmt.Sprintf(`INSERT INTO %[1]s_selection_versions(viewer_did,record_key,event_at,repo_rev,is_deleted)
 SELECT $1,$2,$3,$4,$5 WHERE NOT EXISTS(SELECT 1 FROM %[1]s_selection_sync WHERE viewer_did=$1 AND synced_at>$3)
 ON CONFLICT(viewer_did,record_key) DO UPDATE SET event_at=EXCLUDED.event_at,repo_rev=EXCLUDED.repo_rev,is_deleted=EXCLUDED.is_deleted
 WHERE %[1]s_selection_versions.event_at<EXCLUDED.event_at OR (%[1]s_selection_versions.event_at=EXCLUDED.event_at AND %[1]s_selection_versions.repo_rev<EXCLUDED.repo_rev)
 RETURNING record_key`, topic)
	var accepted string
	err = tx.QueryRowContext(ctx, statement, mutation.ViewerDID, mutation.RecordKey, mutation.EventAt, mutation.RepoRev, mutation.Value == nil).Scan(&accepted)
	if errors.Is(err, sql.ErrNoRows) {
		return tx.Commit()
	}
	if err != nil {
		return err
	}
	if mutation.Value == nil {
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("DELETE FROM %s_selections WHERE viewer_did=$1 AND record_key=$2", topic), mutation.ViewerDID, mutation.RecordKey); err != nil {
			return err
		}
	} else {
		if mutation.Reference == nil {
			return errors.New("selection reference missing")
		}
		statement := fmt.Sprintf(`INSERT INTO %[1]s_selections(viewer_did,record_key,%[2]s,reference,updated_at)VALUES($1,$2,$3,$4,$5)
 ON CONFLICT(viewer_did,record_key) DO UPDATE SET %[2]s=EXCLUDED.%[2]s,reference=EXCLUDED.reference,updated_at=EXCLUDED.updated_at`, topic, field)
		if _, err := tx.ExecContext(ctx, statement, mutation.ViewerDID, mutation.RecordKey, *mutation.Value, *mutation.Reference, mutation.EventAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}
