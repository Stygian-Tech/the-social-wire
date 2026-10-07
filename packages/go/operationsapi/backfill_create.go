package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"strconv"
	"time"
)

// CreateBackfill serializes recovery scope checks and persists job, gap, replay snapshot,
// and audit together. The dry-run token is only consulted after immutable replay lookup.
func (s *PostgresStore) CreateBackfill(ctx context.Context, request CreateBackfillRequest, operatorDID string, requestID *string, at time.Time) (BackfillJob, error) {
	r, err := NormalizeBackfillRequest(request.DryRun)
	if err != nil {
		return BackfillJob{}, err
	}
	canonical := CanonicalBackfillRequest(r)
	estimate := strconv.Itoa(request.ExpectedEstimate)
	fields := map[string]*string{"operatorDid": &operatorDID, "canonicalRequest": &canonical, "expectedEstimate": &estimate, "auditNote": request.AuditNote, "environmentConfirmation": request.EnvironmentConfirmation, "signedRequestFingerprint": &request.RequestFingerprint}
	fingerprint := IdempotencyFingerprint("backfill.queued", "backfill", nil, request.ExpectedGapVersion, fields)
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return BackfillJob{}, err
	}
	defer tx.Rollback(context.Background())
	local, _ := NewPostgresStore(tx, s.Environment)
	audit := MutationAudit{OperatorDID: operatorDID, Action: "backfill.queued", TargetType: "backfill", IdempotencyKey: &request.IdempotencyKey, ExpectedVersion: request.ExpectedGapVersion, Note: request.AuditNote, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	replay, err := local.existingIdempotency(ctx, request.IdempotencyKey, "backfill.queued", "backfill", nil, fingerprint)
	if err != nil {
		return BackfillJob{}, err
	}
	if replay != nil {
		var job BackfillJob
		if json.Unmarshal(replay, &job) != nil || job.ID == "" {
			return BackfillJob{}, ErrIdempotencyConflict
		}
		audit.TargetID = &job.ID
		audit.After = map[string]string{"status": job.Status, "version": strconv.Itoa(job.Version), "targetId": job.ID}
		audit.Outcome = "idempotent_replay"
		if err = local.RecordAudit(ctx, audit); err != nil {
			return BackfillJob{}, err
		}
		return job, tx.Commit(ctx)
	}
	expires, valid := ValidateBackfillFingerprint(request.RequestFingerprint, canonical, request.ExpectedEstimate, s.Environment, s.FingerprintSecret, at)
	if !valid {
		return BackfillJob{}, ErrBackfillFingerprint
	}
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|operations_backfill_scope',0))`, s.Environment); err != nil {
		return BackfillJob{}, err
	}
	if r.GapID != nil {
		gap, err := scanGap(tx.QueryRow(ctx, `SELECT `+gapColumns+` FROM appview_ingestion_gaps WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, *r.GapID), s.Environment)
		if errors.Is(err, pgx.ErrNoRows) {
			return BackfillJob{}, ErrNotFound
		}
		if err != nil {
			return BackfillJob{}, err
		}
		if request.ExpectedGapVersion != nil && gap.Version != *request.ExpectedGapVersion {
			return BackfillJob{}, ErrVersionConflict
		}
		if gap.Status != "confirmed" && gap.Status != "verification_required" {
			return BackfillJob{}, ErrInvalidTransition
		}
		if r.SourceMode == "jetstream_replay" && (!equalCursor(gap.StartCursor, r.StartCursor) || !equalCursor(gap.EndCursor, r.EndCursor)) || len(gap.Collections) > 0 && !intersects(gap.Collections, r.Collections) {
			return BackfillJob{}, ErrBackfillScopeChanged
		}
		audit.Before = map[string]string{"status": gap.Status, "version": strconv.Itoa(gap.Version)}
	} else if r.SourceMode == "jetstream_replay" && r.EndCursor != nil {
		var committed *int64
		err = tx.QueryRow(ctx, `SELECT last_committed_cursor FROM appview_ingestion_stream_state WHERE environment=$1 AND source='jetstream' FOR SHARE`, s.Environment).Scan(&committed)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return BackfillJob{}, err
		}
		if committed != nil && *committed >= *r.EndCursor {
			return BackfillJob{}, ErrBackfillScopeChanged
		}
	}
	rows, err := tx.Query(ctx, `SELECT gap_id,source_mode,start_cursor,end_cursor,collections::text,author_dids::text FROM appview_backfill_jobs WHERE environment=$1 AND status IN ('queued','running','paused') FOR UPDATE`, s.Environment)
	if err != nil {
		return BackfillJob{}, err
	}
	overlap := false
	for rows.Next() {
		job := BackfillJob{Status: "queued"}
		var collections, authors string
		if err = rows.Scan(&job.GapID, &job.SourceMode, &job.StartCursor, &job.EndCursor, &collections, &authors); err != nil {
			rows.Close()
			return BackfillJob{}, err
		}
		if json.Unmarshal([]byte(collections), &job.Collections) != nil || json.Unmarshal([]byte(authors), &job.AuthorDIDs) != nil {
			rows.Close()
			return BackfillJob{}, ErrBackfillScopeChanged
		}
		overlap = overlap || backfillOverlaps(job, r)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return BackfillJob{}, err
	}
	if overlap {
		return BackfillJob{}, ErrOverlappingBackfill
	}
	id, err := randomUUID()
	if err != nil {
		return BackfillJob{}, err
	}
	collections, _ := json.Marshal(r.Collections)
	authors, _ := json.Marshal(r.AuthorDIDs)
	verification := "required"
	if r.SourceMode == "tap_verified_resync" {
		verification = "pending"
	}
	var note *string
	if request.AuditNote != nil {
		v := boundedText(*request.AuditNote, 280)
		note = &v
	}
	_, err = tx.Exec(ctx, `INSERT INTO appview_backfill_jobs(environment,id,gap_id,source_mode,status,start_cursor,end_cursor,checkpoint_cursor,collections,author_dids,batch_size,rate_limit,max_concurrency,estimated_count,requested_by_did,audit_note,idempotency_key,verification_status,request_fingerprint,request_fingerprint_expires_at,normalized_request_hash,created_at,updated_at,version) VALUES($1,$2,$3,$4,'queued',$5,$6,$5,$7::jsonb,$8::jsonb,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$20,0)`, s.Environment, id, r.GapID, r.SourceMode, r.StartCursor, r.EndCursor, string(collections), string(authors), r.BatchSize, r.RateLimit, r.MaxConcurrency, request.ExpectedEstimate, operatorDID, note, request.IdempotencyKey, verification, request.RequestFingerprint, expires, HashIdentity(canonical), at)
	if err != nil {
		return BackfillJob{}, err
	}
	if r.GapID != nil {
		if _, err = tx.Exec(ctx, `UPDATE appview_ingestion_gaps SET status='backfill_queued',backfill_job_id=$3,updated_at=$4,version=version+1 WHERE environment=$1 AND id=$2`, s.Environment, *r.GapID, id, at); err != nil {
			return BackfillJob{}, err
		}
	}
	job, err := local.FetchBackfill(ctx, id)
	if err != nil {
		return BackfillJob{}, err
	}
	if job == nil {
		return BackfillJob{}, ErrNotFound
	}
	if err = local.insertIdempotency(ctx, request.IdempotencyKey, "backfill.queued", "backfill", id, "queued", fingerprint, *job, at); err != nil {
		return BackfillJob{}, err
	}
	audit.TargetID = &id
	audit.After = map[string]string{"status": "queued", "version": "0", "targetId": id}
	audit.Outcome = "succeeded"
	if err = local.RecordAudit(ctx, audit); err != nil {
		return BackfillJob{}, err
	}
	return *job, tx.Commit(ctx)
}
