package operationsapi

import (
	"context"
	"time"
)

func (s *PostgresStore) FetchViewerCounts(ctx context.Context, at time.Time) (*ViewerCounts, error) {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return nil, err
	}
	counts := ViewerCounts{ObservedAt: WireTime{at}}
	err = tx.QueryRow(budget, `WITH viewer_activity AS(SELECT viewer_did,max(updated_at) AS last_seen_at FROM(SELECT viewer_did,updated_at FROM appview_viewer_feeds UNION ALL SELECT viewer_did,updated_at FROM appview_publication_scopes)viewers GROUP BY viewer_did) SELECT count(*),count(*) FILTER(WHERE last_seen_at>=$1),count(*) FILTER(WHERE last_seen_at>=$2) FROM viewer_activity`, at.Add(-7*24*time.Hour), at.Add(-30*24*time.Hour)).Scan(&counts.KnownViewers, &counts.ActiveViewers7d, &counts.ActiveViewers30d)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(budget); err != nil {
		return nil, err
	}
	return &counts, nil
}
func (s *PostgresStore) FetchViewerHistory(ctx context.Context, at time.Time) ([]ViewerCounts, error) {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return nil, err
	}
	rows, err := tx.Query(budget, `SELECT known_viewers,active_viewers_7d,active_viewers_30d,observed_at FROM operations_viewer_daily_counts WHERE environment=$1 AND snapshot_day>=($2::timestamptz AT TIME ZONE 'UTC')::date-89 AND snapshot_day<=($2::timestamptz AT TIME ZONE 'UTC')::date AND observed_at<=$2 ORDER BY snapshot_day ASC LIMIT 90`, s.Environment, at)
	if err != nil {
		return nil, err
	}
	history := []ViewerCounts{}
	for rows.Next() {
		counts := ViewerCounts{}
		var observed time.Time
		if err = rows.Scan(&counts.KnownViewers, &counts.ActiveViewers7d, &counts.ActiveViewers30d, &observed); err != nil {
			rows.Close()
			return nil, err
		}
		counts.ObservedAt = WireTime{observed}
		history = append(history, counts)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(budget); err != nil {
		return nil, err
	}
	return history, nil
}
func (s *PostgresStore) SaveViewerHistory(ctx context.Context, counts ViewerCounts) error {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return err
	}
	_, err = tx.Exec(budget, `INSERT INTO operations_viewer_daily_counts(environment,snapshot_day,known_viewers,active_viewers_7d,active_viewers_30d,observed_at) VALUES($1,($2::timestamptz AT TIME ZONE 'UTC')::date,$3,$4,$5,$2) ON CONFLICT(environment,snapshot_day) DO UPDATE SET known_viewers=EXCLUDED.known_viewers,active_viewers_7d=EXCLUDED.active_viewers_7d,active_viewers_30d=EXCLUDED.active_viewers_30d,observed_at=EXCLUDED.observed_at WHERE operations_viewer_daily_counts.observed_at<EXCLUDED.observed_at`, s.Environment, counts.ObservedAt.Time, counts.KnownViewers, counts.ActiveViewers7d, counts.ActiveViewers30d)
	if err != nil {
		return err
	}
	return tx.Commit(budget)
}
func (s *PostgresStore) RecordViewerHistory(ctx context.Context, at time.Time) error {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return err
	}
	if _, err = tx.Exec(budget, `DELETE FROM operations_viewer_daily_counts WHERE environment=$1 AND snapshot_day<($2::timestamptz AT TIME ZONE 'UTC')::date-89`, s.Environment, at); err != nil {
		return err
	}
	if err = tx.Commit(budget); err != nil {
		return err
	}
	counts, err := s.FetchViewerCounts(ctx, at)
	if err != nil {
		return err
	}
	if counts == nil {
		return nil
	}
	return s.SaveViewerHistory(ctx, *counts)
}
