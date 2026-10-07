package operationscore

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"net"
	"time"
)

// TransientLeaseFailure mirrors the Swift control retry policy without retrying
// authority conflicts, cancellation, or unknown database errors.
func TransientLeaseFailure(err error) bool {
	if errors.Is(err, ErrLeaseConflict) || errors.Is(err, ErrAuthorityExpired) || errors.Is(err, context.Canceled) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "55P03", "57014", "40P01", "40001", "08000", "08003", "08006", "08001", "08004", "57P01", "57P02", "57P03":
			return true
		}
		return false
	}
	var network net.Error
	return errors.As(err, &network)
}
func (s *LeaseSupervisor) renewWithRetry(ctx context.Context, authority RoleLeaseAuthority, deadline func() time.Time) (FencedRoleLease, time.Time, error) {
	for retry := 0; retry <= 2; retry++ {
		remaining := time.Until(deadline())
		if remaining <= 0 || (retry > 0 && remaining <= 3*time.Second) {
			return FencedRoleLease{}, time.Time{}, ErrAuthorityExpired
		}
		started := time.Now()
		attempt, stop := context.WithTimeout(ctx, min(3*time.Second, remaining))
		renewed, err := s.Store.Renew(attempt, authority, s.Config.LeaseDuration)
		stop()
		if err == nil {
			return renewed, started, nil
		}
		s.event("renewal_failed", authority, err)
		if ctx.Err() != nil {
			return FencedRoleLease{}, started, ctx.Err()
		}
		if !TransientLeaseFailure(err) || retry == 2 || time.Until(deadline()) <= 4*time.Second {
			return FencedRoleLease{}, started, err
		}
		s.event("renewal_retry_scheduled", authority, err)
		if err := sleep(ctx, time.Second); err != nil {
			return FencedRoleLease{}, started, err
		}
	}
	return FencedRoleLease{}, time.Time{}, ErrAuthorityExpired
}
