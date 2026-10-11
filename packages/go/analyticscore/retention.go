package analyticscore

import (
	"context"
	"time"
)

// Each sweep removes at most 1000 expired rows per table, avoiding unbounded deletes.
func (s Store) Cleanup(ctx context.Context, now time.Time) error {
	for table, expiry := range map[string]time.Time{"creator_analytics_events": now.UTC().AddDate(0, 0, -30), "creator_analytics_tracking": now.UTC().AddDate(0, 0, -90), "creator_analytics_snapshots": now.UTC().AddDate(0, 0, -90)} {
		if _, e := s.DB.ExecContext(ctx, `DELETE FROM `+table+` WHERE ctid IN (SELECT ctid FROM `+table+` WHERE day<$1 ORDER BY day LIMIT 1000)`, expiry.Format("2006-01-02")); e != nil {
			return e
		}
	}
	for _, table := range []string{"creator_analytics_items", "creator_analytics_refresh"} {
		if _, e := s.DB.ExecContext(ctx, `DELETE FROM `+table+` WHERE ctid IN (SELECT ctid FROM `+table+` WHERE refreshed_at<$1 ORDER BY refreshed_at LIMIT 1000)`, now.AddDate(0, 0, -90)); e != nil {
			return e
		}
	}
	return nil
}
