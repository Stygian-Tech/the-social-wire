package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
	"time"
)

func (s *PostgresStore) databaseExpiryBacklog(ctx context.Context, table string, at time.Time, limit int) (int64, bool, error) {
	limit = max(1, min(limit, 1000))
	selectColumns, count, where, order := "1", "count(*)", "expires_at<=$1", "expires_at"
	args := []any{at, limit + 1}
	switch table {
	case "content_items", "wire_items", "wire_item_aliases", "appview_circle_edition_cache":
	case "wire_rank_generations":
		selectColumns = "is_active"
		count = "count(*) FILTER(WHERE is_active=FALSE)"
	case "appview_circle_graph_snapshots":
		where = "stale_until<=$1"
		order = "stale_until"
	case "operations_metric_rollups":
		selectColumns = "environment"
		count = "count(*) FILTER(WHERE environment=$3::text)"
		args = append(args, s.Environment)
	case "operations_change_events":
		where = "expires_at<=$1 AND environment=$3::text"
		args = append(args, s.Environment)
	case "appview_ingestion_inbox":
		selectColumns = "status,reconciled_at"
		where = "expires_at<=$1 AND environment=$3::text"
		count = "count(*) FILTER(WHERE status IN ('applied','filtered_scope') OR(status='dead_letter' AND reconciled_at IS NOT NULL))"
		args = append(args, s.Environment)
	case "wire_ingestion_inbox":
		selectColumns = "environment,status"
		count = "count(*) FILTER(WHERE environment=$3::text AND status IN ('applied','dead_letter'))"
		args = append(args, s.Environment)
	default:
		return 0, false, errors.New("unsupported expiry observation table")
	}
	query := `SELECT ` + count + `,count(*)>$2-1 FROM(SELECT ` + selectColumns + ` FROM ` + table + ` WHERE ` + where + ` ORDER BY ` + order + ` LIMIT $2) sampled`
	var countValue int64
	var truncated bool
	err := s.databaseCostRead(ctx, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, query, args...).Scan(&countValue, &truncated)
	})
	return countValue, truncated, err
}
