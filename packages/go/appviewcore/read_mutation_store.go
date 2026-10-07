package appviewcore

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

var ErrPDSReadStateRequired = errors.New("PDSReadStateRequired: Update your client to change PDS read state")

type ReadMutationStore struct{ DB *sql.DB }

func (s ReadMutationStore) Put(ctx context.Context, viewer, subject string, read bool, at time.Time) error {
	if viewer == "" || subject == "" {
		return errors.New("viewer and subject required")
	}
	// Share the authority-row lock with verified PDS activation. Checking before
	// locking would allow authority to switch between the check and legacy writes.
	tx, err := beginLegacyMutation(ctx, s.DB, viewer)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Serialize concurrent writes for the same viewer/subject before evaluating
	// its prior state, so duplicate requests cannot adjust a badge twice.
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|' || $2, 150))`, viewer, subject); err != nil {
		return err
	}
	var wasRead bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)
 OR EXISTS(SELECT 1 FROM content_items ci JOIN appview_publication_read_floors floor
 ON floor.viewer_did=$1 AND floor.publication_id=ci.publication_site
 WHERE ci.uri=$2 AND (ci.created_at<floor.read_floor_at OR (ci.created_at=floor.read_floor_at AND (floor.read_floor_uri IS NULL OR ci.uri<=floor.read_floor_uri)))
 AND NOT EXISTS(SELECT 1 FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2))`, viewer, subject).Scan(&wasRead); err != nil {
		return err
	}
	if read {
		if _, err := tx.ExecContext(ctx, `INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3) ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET created_at=EXCLUDED.created_at`, viewer, subject, at); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2`, viewer, subject); err != nil {
			return err
		}
	} else {
		if _, err := tx.ExecContext(ctx, `DELETE FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2`, viewer, subject); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3) ON CONFLICT(viewer_did,subject_uri) DO UPDATE SET created_at=EXCLUDED.created_at`, viewer, subject, at); err != nil {
			return err
		}
	}
	delta := 0
	if read && !wasRead {
		delta = -1
	} else if !read && wasRead {
		delta = 1
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)
 SELECT DISTINCT scope.viewer_did,scope.publication_id,GREATEST(0,$5::integer),$3::bigint,'estimated',TRUE,$4::timestamptz
 FROM appview_publication_scopes scope JOIN content_items ci ON ci.author_did=scope.author_did
 AND (jsonb_array_length(scope.scope_keys)=0 OR scope.scope_keys ? ci.publication_site)
 WHERE scope.viewer_did=$1 AND ci.uri=$2 AND $5::integer<>0
 ON CONFLICT(viewer_did,publication_id) DO UPDATE SET unread_count=GREATEST(0,appview_unread_counters.unread_count+$5),generation=EXCLUDED.generation,accuracy='estimated',dirty=TRUE,counted_at=EXCLUDED.counted_at`, viewer, subject, (at.UnixNano()+500000)/1000000, at, delta); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM unread_counts_cache WHERE viewer_did=$1`, viewer); err != nil {
		return err
	}
	return tx.Commit()
}
