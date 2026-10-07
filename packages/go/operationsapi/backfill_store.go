package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"strconv"
	"time"
)

const backfillColumns = `id,gap_id,source_mode,status,start_cursor,end_cursor,checkpoint_cursor,collections::text,author_dids::text,batch_size,rate_limit,max_concurrency,estimated_count,processed_count,failed_count,reconciled_count,requested_by_did,audit_note,failure_reason,lease_owner,lease_expires_at,created_at,updated_at,completed_at,version,verification_status,verification_reason,scope_truncated,validation_watermark,author_results::text`

func scanBackfill(row interface{ Scan(...any) error }, environment string) (BackfillJob, error) {
	job := BackfillJob{Environment: environment}
	var collections, authors, results string
	var lease, completed *time.Time
	var created, updated time.Time
	err := row.Scan(&job.ID, &job.GapID, &job.SourceMode, &job.Status, &job.StartCursor, &job.EndCursor, &job.CheckpointCursor, &collections, &authors, &job.BatchSize, &job.RateLimit, &job.MaxConcurrency, &job.EstimatedCount, &job.ProcessedCount, &job.FailedCount, &job.ReconciledCount, &job.RequestedByDID, &job.AuditNote, &job.FailureReason, &job.LeaseOwner, &lease, &created, &updated, &completed, &job.Version, &job.VerificationStatus, &job.VerificationReason, &job.ScopeTruncated, &job.ValidationWatermark, &results)
	if err != nil {
		return job, err
	}
	job.CreatedAt = WireTime{created}
	job.UpdatedAt = WireTime{updated}
	if lease != nil {
		job.LeaseExpiresAt = &WireTime{*lease}
	}
	if completed != nil {
		job.CompletedAt = &WireTime{*completed}
	}
	switch job.SourceMode {
	case "tap_verified_resync", "jetstream_replay", "pds_reconciliation":
	default:
		job.SourceMode = "jetstream_replay"
	}
	switch job.Status {
	case "queued", "running", "paused", "completed", "failed", "cancelled":
	default:
		job.Status = "queued"
	}
	switch job.VerificationStatus {
	case "pending", "required", "verified", "failed":
	default:
		job.VerificationStatus = "required"
	}
	if json.Unmarshal([]byte(collections), &job.Collections) != nil || job.Collections == nil {
		job.Collections = []string{}
	}
	if json.Unmarshal([]byte(authors), &job.AuthorDIDs) != nil || job.AuthorDIDs == nil {
		job.AuthorDIDs = []string{}
	}
	if json.Unmarshal([]byte(results), &job.AuthorResults) != nil || job.AuthorResults == nil {
		job.AuthorResults = []BackfillAuthorResult{}
	}
	return job, nil
}
func (s *PostgresStore) FetchBackfill(ctx context.Context, id string) (*BackfillJob, error) {
	job, err := scanBackfill(s.DB.QueryRow(ctx, `SELECT `+backfillColumns+` FROM appview_backfill_jobs WHERE environment=$1 AND id=$2 LIMIT 1`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &job, nil
}
func (s *PostgresStore) ListBackfills(ctx context.Context, view string, limit int, before *string) (Page[BackfillJob], error) {
	if view != "active" && view != "attention" && view != "history" && view != "all" {
		return Page[BackfillJob]{}, HTTPError{400, "Unknown backfill lifecycle view"}
	}
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[BackfillJob]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	const scope = `environment=$1 AND ($2='all' OR ($2='active' AND status IN ('queued','running','paused')) OR ($2='attention' AND status IN ('failed','cancelled')) OR ($2='history' AND status='completed'))`
	rows, err := s.DB.Query(ctx, `SELECT `+backfillColumns+` FROM appview_backfill_jobs WHERE `+scope+` AND ($3::timestamptz IS NULL OR created_at<$3::timestamptz OR (created_at=$3::timestamptz AND id<$4::text)) ORDER BY created_at DESC,id DESC LIMIT $5`, s.Environment, view, date, id, limit+1)
	if err != nil {
		return Page[BackfillJob]{}, err
	}
	jobs := []BackfillJob{}
	for rows.Next() {
		job, err := scanBackfill(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[BackfillJob]{}, err
		}
		jobs = append(jobs, job)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[BackfillJob]{}, err
	}
	page := Page[BackfillJob]{Items: jobs}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM appview_backfill_jobs WHERE `+scope, s.Environment, view).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(jobs) > limit {
		page.Items = jobs[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.CreatedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
func canTransitionBackfill(from, to string) bool {
	allowed := map[string][]string{"queued": {"running", "cancelled"}, "running": {"paused", "completed", "failed", "cancelled"}, "paused": {"queued", "cancelled"}}
	for _, next := range allowed[from] {
		if next == to {
			return true
		}
	}
	return false
}
func linkedGapTransition(from, to string) (allowed []string, next string) {
	switch {
	case from == "queued" && to == "cancelled":
		return []string{"backfill_queued"}, "confirmed"
	case from == "running" && to == "completed":
		return []string{"backfilling"}, "verification_required"
	case (from == "running" && (to == "failed" || to == "cancelled")) || (from == "paused" && to == "cancelled"):
		return []string{"backfilling"}, "confirmed"
	}
	return nil, ""
}
func (s *PostgresStore) TransitionBackfill(ctx context.Context, id, status string, expectedVersion int, operatorDID, key string, requestID, note, failureReason *string, at time.Time) (BackfillJob, error) {
	action := "backfill." + status
	fingerprint := IdempotencyFingerprint(action, "backfill", &id, &expectedVersion, map[string]*string{"operatorDid": &operatorDID, "note": note, "failureReason": failureReason, "status": &status})
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return BackfillJob{}, err
	}
	defer tx.Rollback(context.Background())
	local, _ := NewPostgresStore(tx, s.Environment)
	replay, err := local.existingIdempotency(ctx, key, action, "backfill", &id, fingerprint)
	if err != nil {
		return BackfillJob{}, err
	}
	audit := MutationAudit{OperatorDID: operatorDID, Action: action, TargetType: "backfill", TargetID: &id, IdempotencyKey: &key, ExpectedVersion: &expectedVersion, Note: note, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	if replay != nil {
		var job BackfillJob
		if json.Unmarshal(replay, &job) != nil || job.ID != id {
			return BackfillJob{}, ErrIdempotencyConflict
		}
		if job.AuthorResults == nil {
			job.AuthorResults = []BackfillAuthorResult{}
		}
		audit.After = map[string]string{"status": job.Status, "version": strconv.Itoa(job.Version)}
		audit.Outcome = "idempotent_replay"
		if err = local.RecordAudit(ctx, audit); err != nil {
			return BackfillJob{}, err
		}
		return job, tx.Commit(ctx)
	}
	current, err := scanBackfill(tx.QueryRow(ctx, `SELECT `+backfillColumns+` FROM appview_backfill_jobs WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return BackfillJob{}, ErrNotFound
	}
	if err != nil {
		return BackfillJob{}, err
	}
	if current.Version != expectedVersion {
		return BackfillJob{}, ErrVersionConflict
	}
	if !canTransitionBackfill(current.Status, status) {
		return BackfillJob{}, ErrInvalidTransition
	}
	if operatorDID == "system:worker" && current.Status == "running" && (status == "completed" || status == "failed") {
		if current.LeaseOwner == nil || current.LeaseExpiresAt == nil || current.LeaseExpiresAt.Before(at) {
			return BackfillJob{}, ErrLeaseConflict
		}
	}
	var linked *Gap
	allowed, nextGap := linkedGapTransition(current.Status, status)
	if current.GapID != nil && nextGap != "" {
		gap, err := scanGap(tx.QueryRow(ctx, `SELECT `+gapColumns+` FROM appview_ingestion_gaps WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, *current.GapID), s.Environment)
		if errors.Is(err, pgx.ErrNoRows) {
			return BackfillJob{}, ErrNotFound
		}
		if err != nil {
			return BackfillJob{}, err
		}
		valid := false
		for _, from := range allowed {
			valid = valid || gap.Status == from
		}
		if gap.BackfillJobID == nil || *gap.BackfillJobID != id || !valid {
			return BackfillJob{}, ErrInvalidTransition
		}
		linked = &gap
	}
	var completed *time.Time
	if status == "completed" || status == "failed" || status == "cancelled" {
		completed = &at
	}
	var boundedFailure *string
	if failureReason != nil {
		v := boundedText(*failureReason, 160)
		boundedFailure = &v
	}
	updated, err := scanBackfill(tx.QueryRow(ctx, `UPDATE appview_backfill_jobs SET status=$3,updated_at=$4,completed_at=$5,version=version+1,expires_at=CASE WHEN $3 IN ('completed','failed','cancelled') THEN $6 ELSE expires_at END,failure_reason=CASE WHEN $3='failed' THEN $7 ELSE failure_reason END,lease_owner=NULL,lease_expires_at=NULL WHERE environment=$1 AND id=$2 AND version=$8 RETURNING `+backfillColumns, s.Environment, id, status, at, completed, at.Add(365*24*time.Hour), boundedFailure, expectedVersion), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return BackfillJob{}, ErrVersionConflict
	}
	if err != nil {
		return BackfillJob{}, err
	}
	if linked != nil {
		if status == "completed" && updated.SourceMode == "tap_verified_resync" && updated.VerificationStatus == "verified" && !updated.ScopeTruncated && updated.FailedCount == 0 && updated.ValidationWatermark != nil {
			nextGap = "resolved"
		}
		tag, err := tx.Exec(ctx, `UPDATE appview_ingestion_gaps SET status=$3,updated_at=$4,expires_at=CASE WHEN $3 IN ('resolved','ignored') THEN $5 ELSE expires_at END,version=version+1 WHERE environment=$1 AND id=$2 AND version=$6 AND status=$7`, s.Environment, linked.ID, nextGap, at, at.Add(365*24*time.Hour), linked.Version, linked.Status)
		if err != nil {
			return BackfillJob{}, err
		}
		if tag.RowsAffected() != 1 {
			return BackfillJob{}, ErrInvalidTransition
		}
		if nextGap == "resolved" || nextGap == "ignored" {
			if err = local.extendLifecycleRetention(ctx, "gap", linked.ID, at); err != nil {
				return BackfillJob{}, err
			}
		}
	}
	if completed != nil {
		if err = local.extendLifecycleRetention(ctx, "backfill", id, at); err != nil {
			return BackfillJob{}, err
		}
	}
	if err = local.insertIdempotency(ctx, key, action, "backfill", id, "succeeded", fingerprint, updated, at); err != nil {
		return BackfillJob{}, err
	}
	audit.Before = map[string]string{"status": current.Status, "version": strconv.Itoa(current.Version)}
	audit.After = map[string]string{"status": updated.Status, "version": strconv.Itoa(updated.Version)}
	audit.Outcome = "succeeded"
	if err = local.RecordAudit(ctx, audit); err != nil {
		return BackfillJob{}, err
	}
	return updated, tx.Commit(ctx)
}
