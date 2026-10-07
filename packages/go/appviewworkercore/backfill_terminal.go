package appviewworkercore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var ErrBackfillIdempotency = errors.New("backfill idempotency conflict")

// Terminal is the worker-only completed/failed transition. Diagnostic recovery
// never resolves a linked gap; completion leaves operator verification required.
func (s BackfillStore) Terminal(ctx context.Context, job BackfillJob, status string, reason *string, at time.Time) (BackfillJob, error) {
	if status != "completed" && status != "failed" {
		return job, errors.New("invalid worker terminal status")
	}
	key := "recovery:" + job.ID + ":" + status
	fingerprint := backfillTerminalFingerprint(job, status, reason)
	tx, err := s.transaction(ctx)
	if err != nil {
		return job, err
	}
	defer tx.Rollback()
	var storedFingerprint, storedAction, storedTarget, storedType, storedOutcome, payload string
	err = tx.QueryRowContext(ctx, `SELECT request_fingerprint,action,target_id,target_type,outcome,result_payload::text FROM operations_idempotency_records WHERE environment=$1 AND idempotency_key=$2 FOR UPDATE`, s.Environment, key).Scan(&storedFingerprint, &storedAction, &storedTarget, &storedType, &storedOutcome, &payload)
	if err == nil {
		if storedFingerprint != fingerprint || storedAction != "backfill."+status || storedTarget != job.ID || storedType != "backfill" || storedOutcome != "succeeded" {
			return job, ErrBackfillIdempotency
		}
		var result struct {
			ID, Status string
			Version    int64
		}
		if err := json.Unmarshal([]byte(payload), &result); err != nil || result.ID != job.ID || result.Status != status {
			return job, ErrBackfillIdempotency
		}
		next := job
		next.Version = result.Version
		after, _ := json.Marshal(map[string]string{"status": status, "version": strconv.FormatInt(next.Version, 10)})
		if err := s.auditTerminal(ctx, tx, job, status, key, "{}", string(after), "idempotent_replay", at); err != nil {
			return job, err
		}
		if err := tx.Commit(); err != nil {
			return job, err
		}
		return next, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return job, err
	}
	var gap *string
	var currentVersion int64
	var currentStatus, owner string
	var expires *time.Time
	var source, verification string
	var truncated bool
	var failed int
	var watermark *string
	err = tx.QueryRowContext(ctx, `SELECT gap_id,version,status,COALESCE(lease_owner,''),lease_expires_at,source_mode,verification_status,scope_truncated,failed_count,validation_watermark FROM appview_backfill_jobs WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, job.ID).Scan(&gap, &currentVersion, &currentStatus, &owner, &expires, &source, &verification, &truncated, &failed, &watermark)
	if err != nil {
		return job, err
	}
	if currentVersion != job.Version || currentStatus != "running" || owner != s.WorkerID || expires == nil || expires.Before(at) {
		return job, ErrBackfillLease
	}
	if gap != nil {
		var linkedStatus string
		var linkedJob *string
		if err := tx.QueryRowContext(ctx, `SELECT status,backfill_job_id FROM appview_ingestion_gaps WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, *gap).Scan(&linkedStatus, &linkedJob); err != nil {
			return job, err
		}
		if linkedStatus != "backfilling" || linkedJob == nil || *linkedJob != job.ID {
			return job, errors.New("linked recovery gap transition conflict")
		}
		nextGap := "confirmed"
		if status == "completed" {
			nextGap = "verification_required"
			if source == "tap_verified_resync" && verification == "verified" && !truncated && failed == 0 && watermark != nil {
				nextGap = "resolved"
			}
		}
		_, err = tx.ExecContext(ctx, `UPDATE appview_ingestion_gaps SET status=$3,updated_at=$4,version=version+1,expires_at=CASE WHEN $3='resolved' THEN $5 ELSE expires_at END WHERE environment=$1 AND id=$2`, s.Environment, *gap, nextGap, at, at.Add(365*24*time.Hour))
		if err != nil {
			return job, err
		}
		if nextGap == "resolved" {
			if err := s.extendRecoveryRetention(ctx, tx, "gap", *gap, at); err != nil {
				return job, err
			}
		}
	}
	var boundedReason *string
	if reason != nil {
		text := string([]rune(*reason)[:min(160, len([]rune(*reason)))])
		boundedReason = &text
	}
	next, err := scanBackfill(tx.QueryRowContext(ctx, `UPDATE appview_backfill_jobs SET status=$5,updated_at=$6,completed_at=$6,expires_at=$7,version=version+1,lease_owner=NULL,lease_expires_at=NULL,failure_reason=CASE WHEN $5='failed' THEN $8 ELSE failure_reason END WHERE environment=$1 AND id=$2 AND version=$3 AND lease_owner=$4 RETURNING `+backfillColumns, s.Environment, job.ID, job.Version, s.WorkerID, status, at, at.Add(365*24*time.Hour), boundedReason))
	if errors.Is(err, sql.ErrNoRows) {
		return job, ErrBackfillLease
	}
	if err != nil {
		return job, err
	}
	if err := s.extendRecoveryRetention(ctx, tx, "backfill", job.ID, at); err != nil {
		return job, err
	}
	if err := tx.QueryRowContext(ctx, `SELECT `+backfillPayload+`::text FROM appview_backfill_jobs WHERE environment=$1 AND id=$2`, s.Environment, job.ID).Scan(&payload); err != nil {
		return job, err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO operations_idempotency_records(environment,idempotency_key,action,target_type,target_id,outcome,request_fingerprint,result_payload,created_at,expires_at)VALUES($1,$2,$3,'backfill',$4,'succeeded',$5,$6::jsonb,$7,$8)`, s.Environment, key, "backfill."+status, job.ID, fingerprint, payload, at, at.Add(365*24*time.Hour))
	if err != nil {
		return job, err
	}
	before, _ := json.Marshal(map[string]string{"status": "running", "version": strconv.FormatInt(job.Version, 10)})
	after, _ := json.Marshal(map[string]string{"status": status, "version": strconv.FormatInt(next.Version, 10)})
	if err := s.auditTerminal(ctx, tx, job, status, key, string(before), string(after), "succeeded", at); err != nil {
		return job, err
	}
	if err := tx.Commit(); err != nil {
		return job, err
	}
	return next, nil
}
func (s BackfillStore) auditTerminal(ctx context.Context, tx *sql.Tx, job BackfillJob, status, key, before, after, outcome string, at time.Time) error {
	id, err := newSnapshotToken()
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO operations_audit_events(environment,id,operator_did,action,target_type,target_id,idempotency_key,expected_version,before_state,after_state,outcome,occurred_at,expires_at)VALUES($1,$2,'system:worker',$3,'backfill',$4,$5,$6,$7::jsonb,$8::jsonb,$9,$10,$11)`, s.Environment, id, "backfill."+status, job.ID, key, job.Version, before, after, outcome, at, at.Add(365*24*time.Hour))
	return err
}
func (s BackfillStore) extendRecoveryRetention(ctx context.Context, tx *sql.Tx, target, id string, at time.Time) error {
	for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
		if _, err := tx.ExecContext(ctx, `UPDATE `+table+` SET expires_at=$4 WHERE environment=$1 AND target_type=$2 AND target_id=$3`, s.Environment, target, id, at.Add(365*24*time.Hour)); err != nil {
			return err
		}
	}
	return nil
}
func backfillTerminalFingerprint(job BackfillJob, status string, reason *string) string {
	failure := "<nil>"
	if reason != nil {
		failure = *reason
	}
	fields := [][2]string{{"action", "backfill." + status}, {"targetType", "backfill"}, {"targetId", job.ID}, {"expectedVersion", strconv.FormatInt(job.Version, 10)}, {"failureReason", failure}, {"note", "<nil>"}, {"operatorDid", "system:worker"}, {"status", status}}
	var input strings.Builder
	for _, field := range fields {
		fmt.Fprintf(&input, "%d:%s%d:%s", len(field[0]), field[0], len(field[1]), field[1])
	}
	digest := sha256.Sum256([]byte(input.String()))
	return hex.EncodeToString(digest[:])
}

// Operations' persisted DTO uses Swift's reference date (2001), not API ISO dates.
const backfillPayload = `jsonb_strip_nulls(jsonb_build_object('id',id,'environment',environment,'gapId',gap_id,'sourceMode',source_mode,'status',status,'startCursor',start_cursor,'endCursor',end_cursor,'checkpointCursor',checkpoint_cursor,'collections',collections,'authorDids',author_dids,'authorResults',author_results,'batchSize',batch_size,'rateLimit',rate_limit,'maxConcurrency',max_concurrency,'estimatedCount',estimated_count,'processedCount',processed_count,'failedCount',failed_count,'reconciledCount',reconciled_count,'requestedByDid',requested_by_did,'auditNote',audit_note,'failureReason',failure_reason,'leaseOwner',lease_owner,'leaseExpiresAt',extract(epoch from lease_expires_at)-978307200,'createdAt',extract(epoch from created_at)-978307200,'updatedAt',extract(epoch from updated_at)-978307200,'completedAt',extract(epoch from completed_at)-978307200,'version',version,'verificationStatus',verification_status,'verificationReason',verification_reason,'scopeTruncated',scope_truncated,'validationWatermark',validation_watermark))`
