package operationsapi

import (
	"context"
	"strings"
	"time"
)

func (s *PostgresStore) loadInboxMetrics(ctx context.Context) (map[string]InboxMetrics, error) {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s';SET LOCAL lock_timeout='500ms'`); err != nil {
		return nil, err
	}
	rows, err := tx.Query(budget, `SELECT source_generation,count(*) FILTER(WHERE status='pending'),count(*) FILTER(WHERE status='leased'),count(*) FILTER(WHERE status='retry'),count(*) FILTER(WHERE status='applied'),count(*) FILTER(WHERE status='filtered_scope'),count(*) FILTER(WHERE status='dead_letter' AND reconciled_at IS NULL),count(*),min(staged_at) FILTER(WHERE status IN ('pending','leased','retry')) FROM appview_ingestion_inbox WHERE environment=$1 GROUP BY source_generation`, s.Environment)
	if err != nil {
		return nil, err
	}
	result := map[string]InboxMetrics{}
	for rows.Next() {
		var key string
		var value InboxMetrics
		var oldest *time.Time
		if err = rows.Scan(&key, &value.Pending, &value.Leased, &value.Retrying, &value.Applied, &value.FilteredScope, &value.DeadLetters, &value.Total, &oldest); err != nil {
			rows.Close()
			return nil, err
		}
		if oldest != nil {
			value.OldestPendingAt = &WireTime{*oldest}
		}
		result[key] = value
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(budget); err != nil {
		return nil, err
	}
	if err = budget.Err(); err != nil {
		return nil, err
	}
	return result, nil
}
func (s *PostgresStore) FetchIngestionDurabilitySnapshot(ctx context.Context, at time.Time) (DurabilitySnapshot, error) {
	columns := strings.Replace(durabilitycheckpointColumns, "intake_heartbeat_at", `(SELECT max(lease.updated_at) FROM appview_ingestion_leases lease WHERE lease.environment=checkpoint.environment AND lease.source_generation=checkpoint.source_generation AND lease.released_at IS NULL AND lease.lease_expires_at>=$2) AS intake_heartbeat_at`, 1)
	rows, err := s.DB.Query(ctx, `SELECT `+columns+` FROM appview_jetstream_checkpoints checkpoint WHERE checkpoint.environment=$1 ORDER BY checkpoint.updated_at DESC,checkpoint.source_generation`, s.Environment, at)
	if err != nil {
		return DurabilitySnapshot{}, err
	}
	checkpoints := []DurabilityCheckpoint{}
	for rows.Next() {
		checkpoint, err := scanDurabilityCheckpoint(rows)
		if err != nil {
			rows.Close()
			return DurabilitySnapshot{}, err
		}
		checkpoints = append(checkpoints, checkpoint)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return DurabilitySnapshot{}, err
	}
	inboxByGeneration, err := s.InboxCache.Value(ctx, s.loadInboxMetrics)
	if err != nil {
		return DurabilitySnapshot{}, err
	}
	total := InboxMetrics{}
	for key, value := range inboxByGeneration {
		value = ageInbox(value, at)
		inboxByGeneration[key] = value
		total.Pending += value.Pending
		total.Leased += value.Leased
		total.Retrying += value.Retrying
		total.Applied += value.Applied
		total.FilteredScope += value.FilteredScope
		total.DeadLetters += value.DeadLetters
		total.Total += value.Total
		if value.OldestPendingAt != nil && (total.OldestPendingAt == nil || value.OldestPendingAt.Before(total.OldestPendingAt.Time)) {
			total.OldestPendingAt = value.OldestPendingAt
		}
	}
	total = ageInbox(total, at)
	incidents := IncidentMetrics{}
	var latest *time.Time
	err = s.DB.QueryRow(ctx, `SELECT count(*) FILTER(WHERE status='open'),count(*) FILTER(WHERE status='recovering'),count(*) FILTER(WHERE status='verification_required'),count(*) FILTER(WHERE status='resolved'),count(*) FILTER(WHERE status='ignored'),max(last_detected_at) FROM appview_ingestion_incidents WHERE environment=$1`, s.Environment).Scan(&incidents.Open, &incidents.Recovering, &incidents.VerificationRequired, &incidents.Resolved, &incidents.Ignored, &latest)
	if err != nil {
		return DurabilitySnapshot{}, err
	}
	if latest != nil {
		incidents.LatestDetectedAt = &WireTime{*latest}
	}
	var bytes int64
	if err = s.DB.QueryRow(ctx, `SELECT coalesce(sum(bytes_downloaded),0)::bigint FROM appview_ingestion_replay_usage WHERE environment=$1 AND bucket_started_at>$2`, s.Environment, at.Add(-24*time.Hour)).Scan(&bytes); err != nil {
		return DurabilitySnapshot{}, err
	}
	return DurabilitySnapshot{Environment: s.Environment, Checkpoints: checkpoints, Inbox: total, InboxBySourceGeneration: inboxByGeneration, Incidents: incidents, ReplayBytesRolling24Hours: bytes, GeneratedAt: WireTime{at}}, nil
}
func (s *PostgresStore) ListIngestionIncidents(ctx context.Context, limit int, before *string) (Page[IngestionIncident], error) {
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[IngestionIncident]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	rows, err := s.DB.Query(ctx, `SELECT `+ingestionincidentColumns+` FROM appview_ingestion_incidents WHERE environment=$1 AND ($2::timestamptz IS NULL OR last_detected_at<$2::timestamptz OR(last_detected_at=$2::timestamptz AND id<$3::text)) ORDER BY last_detected_at DESC,id DESC LIMIT $4`, s.Environment, date, id, limit+1)
	if err != nil {
		return Page[IngestionIncident]{}, err
	}
	items := []IngestionIncident{}
	for rows.Next() {
		incident, err := scanIngestionIncident(rows)
		if err != nil {
			rows.Close()
			return Page[IngestionIncident]{}, err
		}
		items = append(items, incident)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[IngestionIncident]{}, err
	}
	page := Page[IngestionIncident]{Items: items}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM appview_ingestion_incidents WHERE environment=$1`, s.Environment).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(items) > limit {
		page.Items = items[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.LastDetectedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
