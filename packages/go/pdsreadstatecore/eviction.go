package pdsreadstatecore

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// EvictIdle never changes PDS authority or legacy marks. It makes the projection
// unavailable before removing bounded rows, under the same authority lock.
func (s *Store) EvictIdle(ctx context.Context, before, at time.Time, batchSize int) (string, int, bool, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, false, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='5s'`); err != nil {
		return "", 0, false, err
	}
	var viewer string
	var wasReady bool
	err = tx.QueryRowContext(ctx, `SELECT a.viewer_did,a.projection_ready FROM appview_pds_read_state_authority a
WHERE a.manifest_cid IS NOT NULL AND ((a.projection_ready AND a.last_accessed_at<$1) OR (NOT a.projection_ready AND
(EXISTS(SELECT 1 FROM appview_pds_read_state_exact e WHERE e.viewer_did=a.viewer_did) OR EXISTS(SELECT 1 FROM appview_pds_read_state_boundaries b WHERE b.viewer_did=a.viewer_did))))
AND NOT EXISTS(SELECT 1 FROM appview_ingestion_inbox i WHERE i.repo_did=a.viewer_did AND i.status IN('pending','retry','leased','dead_letter'))
AND NOT EXISTS(SELECT 1 FROM appview_ingestion_reconciliation_requests r WHERE r.repo_did=a.viewer_did AND r.status IN('pending','leased','failed'))
AND NOT EXISTS(SELECT 1 FROM appview_ingestion_leases l WHERE l.lease_name='pds-read-state-rebuild:'||encode(sha256(convert_to(a.viewer_did,'UTF8')),'hex') AND l.released_at IS NULL AND l.lease_expires_at>$2)
ORDER BY a.projection_ready,a.last_accessed_at,a.viewer_did LIMIT 1 FOR UPDATE OF a SKIP LOCKED`, before, at).Scan(&viewer, &wasReady)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", 0, false, nil
		}
		return "", 0, false, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE appview_pds_read_state_authority SET projection_ready=FALSE WHERE viewer_did=$1 AND projection_ready`, viewer); err != nil {
		return "", 0, false, err
	}
	limit := max(1, min(batchSize, 1000))
	deleted := 0
	for _, table := range []string{"appview_pds_read_state_exact", "appview_pds_read_state_boundaries"} {
		var count int
		if err := tx.QueryRowContext(ctx, `WITH removed AS(DELETE FROM `+table+` WHERE ctid IN(SELECT ctid FROM `+table+` WHERE viewer_did=$1 LIMIT $2) RETURNING 1) SELECT COUNT(*)::int FROM removed`, viewer, limit).Scan(&count); err != nil {
			return "", 0, false, err
		}
		deleted += count
	}
	if err := tx.Commit(); err != nil {
		return "", 0, false, err
	}
	if !wasReady {
		viewer = ""
	}
	return viewer, deleted, true, nil
}
