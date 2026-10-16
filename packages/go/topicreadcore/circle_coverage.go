package topicreadcore

import (
	"context"
	"time"
)

// Coverage is current authority metadata, separate from cached personalized
// presentation. Unknown coverage stays visibly degraded without bypassing any
// moderation checks or discarding an otherwise usable edition.
func (s *CirclePrivateState) recoveryCoverageDegraded(ctx context.Context) bool {
	if s == nil || s.DB == nil {
		return true
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var recovering bool
	if err := s.DB.QueryRowContext(ctx, `SELECT recovering FROM wire_publication_recovery_health`).Scan(&recovering); err != nil {
		return true
	}
	return recovering
}
