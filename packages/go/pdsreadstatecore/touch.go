package pdsreadstatecore

import (
	"context"
	"time"
)

// Touch coalesces access writes to one per hour before a projection-backed read.
func (s *Store) Touch(ctx context.Context, viewer string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE appview_pds_read_state_authority SET last_accessed_at=$2 WHERE viewer_did=$1 AND manifest_cid IS NOT NULL AND last_accessed_at<=$3`, viewer, at, at.Add(-time.Hour))
	return err
}
