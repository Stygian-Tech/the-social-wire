package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"strconv"
	"time"
)

type Gap struct {
	ID              string    `json:"id"`
	Environment     string    `json:"environment"`
	Source          string    `json:"source"`
	StartCursor     *int64    `json:"startCursor,omitempty"`
	EndCursor       *int64    `json:"endCursor,omitempty"`
	StartTime       *WireTime `json:"startTime,omitempty"`
	EndTime         *WireTime `json:"endTime,omitempty"`
	Reason          string    `json:"reason"`
	Status          string    `json:"status"`
	Collections     []string  `json:"collections"`
	DetectedAt      WireTime  `json:"detectedAt"`
	UpdatedAt       WireTime  `json:"updatedAt"`
	BackfillJobID   *string   `json:"backfillJobId,omitempty"`
	DiscoveredCount int       `json:"discoveredCount"`
	ProcessedCount  int       `json:"processedCount"`
	FailedCount     int       `json:"failedCount"`
	ReconciledCount int       `json:"reconciledCount"`
	Version         int       `json:"version"`
}
type Page[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"nextCursor,omitempty"`
	TotalCount int     `json:"totalCount"`
}

const gapColumns = `id,source,start_cursor,end_cursor,start_time,end_time,reason,status,collections::text,detected_at,updated_at,backfill_job_id,discovered_count,processed_count,failed_count,reconciled_count,version`

func scanGap(row interface{ Scan(...any) error }, environment string) (Gap, error) {
	g := Gap{Environment: environment}
	var collections string
	var start, end *time.Time
	var detected, updated time.Time
	err := row.Scan(&g.ID, &g.Source, &g.StartCursor, &g.EndCursor, &start, &end, &g.Reason, &g.Status, &collections, &detected, &updated, &g.BackfillJobID, &g.DiscoveredCount, &g.ProcessedCount, &g.FailedCount, &g.ReconciledCount, &g.Version)
	if err != nil {
		return g, err
	}
	if start != nil {
		g.StartTime = &WireTime{*start}
	}
	if end != nil {
		g.EndTime = &WireTime{*end}
	}
	g.DetectedAt = WireTime{detected}
	g.UpdatedAt = WireTime{updated}
	switch g.Status {
	case "suspected", "confirmed", "backfill_queued", "backfilling", "verification_required", "resolved", "ignored":
	default:
		g.Status = "suspected"
	}
	if json.Unmarshal([]byte(collections), &g.Collections) != nil || g.Collections == nil {
		g.Collections = []string{}
	}
	return g, nil
}
func (s *PostgresStore) FetchGap(ctx context.Context, id string) (*Gap, error) {
	gap, err := scanGap(s.DB.QueryRow(ctx, `SELECT `+gapColumns+` FROM appview_ingestion_gaps WHERE environment=$1 AND id=$2 LIMIT 1`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &gap, nil
}
func (s *PostgresStore) ListGaps(ctx context.Context, view string, limit int, before *string) (Page[Gap], error) {
	if view != "active" && view != "history" && view != "all" {
		return Page[Gap]{}, HTTPError{400, "Unknown gap lifecycle view"}
	}
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[Gap]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	const scope = `environment=$1 AND ($2='all' OR ($2='active' AND status NOT IN ('resolved','ignored')) OR ($2='history' AND status IN ('resolved','ignored')))`
	rows, err := s.DB.Query(ctx, `SELECT `+gapColumns+` FROM appview_ingestion_gaps WHERE `+scope+` AND ($3::timestamptz IS NULL OR detected_at<$3::timestamptz OR (detected_at=$3::timestamptz AND id<$4::text)) ORDER BY detected_at DESC,id DESC LIMIT $5`, s.Environment, view, date, id, limit+1)
	if err != nil {
		return Page[Gap]{}, err
	}
	var gaps = []Gap{}
	for rows.Next() {
		gap, err := scanGap(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[Gap]{}, err
		}
		gaps = append(gaps, gap)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[Gap]{}, err
	}
	page := Page[Gap]{Items: gaps}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM appview_ingestion_gaps WHERE `+scope, s.Environment, view).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(gaps) > limit {
		page.Items = gaps[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.DetectedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
func canTransitionGap(from, to string) bool {
	allowed := map[string][]string{"suspected": {"confirmed", "resolved", "ignored"}, "confirmed": {"backfill_queued", "ignored"}, "backfill_queued": {"backfilling", "confirmed"}, "backfilling": {"resolved", "verification_required", "confirmed"}, "verification_required": {"resolved", "confirmed", "backfill_queued", "ignored"}}
	for _, next := range allowed[from] {
		if next == to {
			return true
		}
	}
	return false
}
func (s *PostgresStore) TransitionGap(ctx context.Context, id, status string, expectedVersion int, operatorDID, key string, requestID, note *string, at time.Time) (Gap, error) {
	action := "gap." + status
	fingerprint := IdempotencyFingerprint(action, "gap", &id, &expectedVersion, map[string]*string{"operatorDid": &operatorDID, "note": note, "status": &status})
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Gap{}, err
	}
	defer tx.Rollback(context.Background())
	local, _ := NewPostgresStore(tx, s.Environment)
	replay, err := local.existingIdempotency(ctx, key, action, "gap", &id, fingerprint)
	if err != nil {
		return Gap{}, err
	}
	audit := MutationAudit{OperatorDID: operatorDID, Action: action, TargetType: "gap", TargetID: &id, IdempotencyKey: &key, ExpectedVersion: &expectedVersion, Note: note, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	if replay != nil {
		var gap Gap
		if json.Unmarshal(replay, &gap) != nil || gap.ID != id {
			return Gap{}, ErrIdempotencyConflict
		}
		audit.After = map[string]string{"status": gap.Status, "version": strconv.Itoa(gap.Version)}
		audit.Outcome = "idempotent_replay"
		if err = local.RecordAudit(ctx, audit); err != nil {
			return Gap{}, err
		}
		return gap, tx.Commit(ctx)
	}
	current, err := scanGap(tx.QueryRow(ctx, `SELECT `+gapColumns+` FROM appview_ingestion_gaps WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return Gap{}, ErrNotFound
	}
	if err != nil {
		return Gap{}, err
	}
	if current.Version != expectedVersion {
		return Gap{}, ErrVersionConflict
	}
	if !canTransitionGap(current.Status, status) {
		return Gap{}, ErrInvalidTransition
	}
	updated, err := scanGap(tx.QueryRow(ctx, `UPDATE appview_ingestion_gaps SET status=$3,updated_at=$4,expires_at=CASE WHEN $3 IN ('resolved','ignored') THEN $5 ELSE expires_at END,version=version+1 WHERE environment=$1 AND id=$2 AND version=$6 RETURNING `+gapColumns, s.Environment, id, status, at, at.Add(365*24*time.Hour), expectedVersion), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return Gap{}, ErrVersionConflict
	}
	if err != nil {
		return Gap{}, err
	}
	if status == "resolved" || status == "ignored" {
		if err = local.extendLifecycleRetention(ctx, "gap", id, at); err != nil {
			return Gap{}, err
		}
	}
	if err = local.insertIdempotency(ctx, key, action, "gap", id, "succeeded", fingerprint, updated, at); err != nil {
		return Gap{}, err
	}
	audit.Before = map[string]string{"status": current.Status, "version": strconv.Itoa(current.Version)}
	audit.After = map[string]string{"status": status, "version": strconv.Itoa(updated.Version)}
	audit.Outcome = "succeeded"
	if err = local.RecordAudit(ctx, audit); err != nil {
		return Gap{}, err
	}
	return updated, tx.Commit(ctx)
}
