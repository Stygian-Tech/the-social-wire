package thinappviewcore

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type RetentionStore struct{ DB *sql.DB }

func (s RetentionStore) DeleteBatch(ctx context.Context, environment string, at, readCutoff time.Time, limit int, tapEnabled, postgresCache bool) ([]int64, error) {
	limit = max(1, min(limit, 10000))
	counts := []int64{}
	type target struct {
		table, where, order string
		args                []any
	}
	targets := []target{
		{"content_items", "expires_at<=$1", "expires_at,uri", []any{at}},
		{"read_marks", "created_at<=$1 AND NOT EXISTS(SELECT 1 FROM appview_pds_read_state_authority authority WHERE authority.viewer_did=read_marks.viewer_did AND authority.manifest_cid IS NOT NULL)", "created_at,viewer_did,subject_uri", []any{readCutoff}},
		{"appview_ingestion_inbox", "environment=$1 AND expires_at<=$2 AND(status IN('applied','filtered_scope')OR(status='dead_letter'AND reconciled_at IS NOT NULL))", "expires_at,seq", []any{environment, at}},
		{"appview_circle_graph_snapshots", "stale_until<=$1", "stale_until,viewer_key_hash", []any{at}},
		{"appview_circle_edition_cache", "expires_at<=$1", "expires_at,viewer_key_hash", []any{at}},
	}
	if tapEnabled {
		targets = append(targets, target{"appview_tap_event_receipts", "environment=$1 AND expires_at<=$2", "expires_at,event_id", []any{environment, at}}, target{"appview_projection_repair_outbox", "environment=$1 AND status='failed'AND expires_at<=$2", "expires_at,id", []any{environment, at}})
	}
	if postgresCache {
		for _, table := range []string{"sidebar_projection_cache", "unread_counts_cache", "first_page_cache"} {
			targets = append(targets, target{table, "expires_at<=$1", "expires_at", []any{at}})
		}
	}
	for _, target := range targets {
		args := append(target.args, limit)
		statement := fmt.Sprintf(`WITH doomed AS(SELECT ctid FROM %s WHERE %s ORDER BY %s LIMIT $%d FOR UPDATE SKIP LOCKED)DELETE FROM %s target USING doomed WHERE target.ctid=doomed.ctid`, target.table, target.where, target.order, len(args), target.table)
		result, err := s.DB.ExecContext(ctx, statement, args...)
		if err != nil {
			return counts, err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return counts, err
		}
		counts = append(counts, count)
	}
	return counts, nil
}
