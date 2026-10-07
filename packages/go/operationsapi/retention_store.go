package operationsapi

import (
	"context"
	"time"
)

// CleanupExpired retains unreconciled canonical dead letters and pending work.
func (s *PostgresStore) CleanupExpired(ctx context.Context, at time.Time, batchSize int) (int64, error) {
	batchSize = max(1, min(batchSize, 10000))
	var affected int64
	if err := s.DB.QueryRow(ctx, `SELECT operations_cleanup_expired($1,$2,$3::integer)::bigint`, s.Environment, at, batchSize).Scan(&affected); err != nil {
		return affected, err
	}
	queries := []struct {
		sql  string
		args []any
	}{
		{`WITH expired AS (SELECT environment,source_generation,seq FROM appview_ingestion_inbox WHERE environment=$1 AND expires_at<=$2 AND (status IN ('applied','filtered_scope') OR (status='dead_letter' AND reconciled_at IS NOT NULL)) ORDER BY expires_at LIMIT $3 FOR UPDATE SKIP LOCKED) DELETE FROM appview_ingestion_inbox inbox USING expired WHERE inbox.environment=expired.environment AND inbox.source_generation=expired.source_generation AND inbox.seq=expired.seq`, []any{s.Environment, at, batchSize}},
		{`DELETE FROM appview_ingestion_replay_usage WHERE ctid IN (SELECT ctid FROM appview_ingestion_replay_usage WHERE environment=$1 AND bucket_started_at<=$2 LIMIT $3)`, []any{s.Environment, at.Add(-48 * time.Hour), batchSize}},
		{`DELETE FROM appview_ingestion_reconciliation_requests WHERE ctid IN (SELECT ctid FROM appview_ingestion_reconciliation_requests WHERE environment=$1 AND status IN ('completed','failed') AND updated_at<=$2 LIMIT $3)`, []any{s.Environment, at.Add(-30 * 24 * time.Hour), batchSize}},
	}
	for _, query := range queries {
		result, err := s.DB.Exec(ctx, query.sql, query.args...)
		if err != nil {
			return affected, err
		}
		affected += result.RowsAffected()
	}
	return affected, nil
}
