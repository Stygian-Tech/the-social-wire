package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

// BackfillStore serializes worker progress with operator pause/cancel actions.
// Every mutation holds the coordinator role fence and the job version fence.
type BackfillStore struct {
	DB                    *sql.DB
	Authority             operationscore.RoleLeaseAuthority
	Environment, WorkerID string
}
type BackfillJob struct {
	ID                                                                  string
	GapID                                                               *string
	SourceMode                                                          string
	StartCursor, EndCursor, CheckpointCursor                            *int64
	Collections, AuthorDIDs                                             []string
	BatchSize, RateLimit, MaxConcurrency, Processed, Failed, Reconciled int
	Version                                                             int64
}

var ErrBackfillLease = errors.New("backfill ownership or version changed")

const backfillColumns = `id,gap_id,source_mode,start_cursor,end_cursor,checkpoint_cursor,collections::text,author_dids::text,batch_size,rate_limit,max_concurrency,processed_count,failed_count,reconciled_count,version`

func scanBackfill(row interface{ Scan(...any) error }) (BackfillJob, error) {
	var j BackfillJob
	var collections, authors string
	err := row.Scan(&j.ID, &j.GapID, &j.SourceMode, &j.StartCursor, &j.EndCursor, &j.CheckpointCursor, &collections, &authors, &j.BatchSize, &j.RateLimit, &j.MaxConcurrency, &j.Processed, &j.Failed, &j.Reconciled, &j.Version)
	if err != nil {
		return j, err
	}
	if err = json.Unmarshal([]byte(collections), &j.Collections); err != nil {
		return j, err
	}
	err = json.Unmarshal([]byte(authors), &j.AuthorDIDs)
	return j, err
}
func (s BackfillStore) transaction(ctx context.Context) (*sql.Tx, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "SET LOCAL statement_timeout='2s'"); err != nil {
		tx.Rollback()
		return nil, err
	}
	if err = operationscore.LockRoleLeaseFence(ctx, tx, s.Authority, false); err != nil {
		tx.Rollback()
		return nil, err
	}
	return tx, nil
}
func (s BackfillStore) Claim(ctx context.Context, at time.Time) (*BackfillJob, error) {
	tx, err := s.transaction(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	job, err := scanBackfill(tx.QueryRowContext(ctx, `UPDATE appview_backfill_jobs SET status='running',lease_owner=$2,lease_expires_at=$3,updated_at=$4,version=version+1 WHERE environment=$1 AND id=(SELECT id FROM appview_backfill_jobs WHERE environment=$1 AND status IN('queued','running') AND(lease_expires_at IS NULL OR lease_expires_at<$4)ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING `+backfillColumns, s.Environment, s.WorkerID, at.Add(time.Minute), at))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if job.GapID != nil {
		if _, err = tx.ExecContext(ctx, `UPDATE appview_ingestion_gaps SET status='backfilling',updated_at=$3,version=version+1 WHERE environment=$1 AND id=$2 AND status='backfill_queued'`, s.Environment, *job.GapID, at); err != nil {
			return nil, err
		}
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return &job, nil
}
func (s BackfillStore) Checkpoint(ctx context.Context, job BackfillJob, at time.Time) (BackfillJob, error) {
	if job.Processed < 0 || job.Failed < 0 || job.Reconciled < 0 || job.Failed > job.Processed || job.Reconciled > job.Processed {
		return job, errors.New("invalid backfill progress")
	}
	tx, err := s.transaction(ctx)
	if err != nil {
		return job, err
	}
	defer tx.Rollback()
	next, err := scanBackfill(tx.QueryRowContext(ctx, `UPDATE appview_backfill_jobs SET checkpoint_cursor=COALESCE($5,checkpoint_cursor),processed_count=$6,failed_count=$7,reconciled_count=$8,lease_expires_at=$9,updated_at=$10,version=version+1 WHERE environment=$1 AND id=$2 AND status='running' AND lease_owner=$3 AND version=$4 AND lease_expires_at>=$10 AND processed_count<=$6 AND failed_count<=$7 AND reconciled_count<=$8 AND($5::bigint IS NULL OR ((checkpoint_cursor IS NULL OR checkpoint_cursor<=$5)AND(start_cursor IS NULL OR start_cursor<=$5)AND(end_cursor IS NULL OR end_cursor>=$5)))RETURNING `+backfillColumns, s.Environment, job.ID, s.WorkerID, job.Version, job.CheckpointCursor, job.Processed, job.Failed, job.Reconciled, at.Add(time.Minute), at))
	if errors.Is(err, sql.ErrNoRows) {
		return job, ErrBackfillLease
	}
	if err != nil {
		return job, err
	}
	if err = tx.Commit(); err != nil {
		return job, err
	}
	return next, nil
}

// BackfillAuthorResult preserves the Operations diagnostic report wire shape.
type BackfillAuthorResult struct {
	DID             string  `json:"did"`
	Collection      string  `json:"collection"`
	DiscoveredCount int     `json:"discoveredCount"`
	ProcessedCount  int     `json:"processedCount"`
	FailedCount     int     `json:"failedCount"`
	Capped          bool    `json:"capped"`
	Truncated       bool    `json:"truncated"`
	Status          string  `json:"status"`
	Error           *string `json:"error,omitempty"`
}

func (s BackfillStore) AuthorResults(ctx context.Context, job BackfillJob, results []BackfillAuthorResult, at time.Time) (BackfillJob, error) {
	if len(results) > 5000 {
		return job, errors.New("too many author reports")
	}
	for _, result := range results {
		if !recoveryDIDValid(result.DID) || result.Collection == "" || utf8.RuneCountInString(result.Collection) > 200 || result.DiscoveredCount < 0 || result.ProcessedCount < 0 || result.FailedCount < 0 || result.ProcessedCount > result.DiscoveredCount || result.FailedCount != result.DiscoveredCount-result.ProcessedCount {
			return job, errors.New("invalid author recovery report")
		}
		if result.Error != nil {
			if len(*result.Error) > 240 {
				return job, errors.New("author error too long")
			}
			for _, c := range *result.Error {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune("_,-", c)) {
					return job, errors.New("unsafe author error category")
				}
			}
		}
		switch result.Status {
		case "succeeded", "partial", "failed", "cancelled", "unsupported":
		default:
			return job, errors.New("invalid author report status")
		}
	}
	encoded, err := json.Marshal(results)
	if err != nil {
		return job, err
	}
	tx, err := s.transaction(ctx)
	if err != nil {
		return job, err
	}
	defer tx.Rollback()
	next, err := scanBackfill(tx.QueryRowContext(ctx, `UPDATE appview_backfill_jobs SET author_results=$5::jsonb,updated_at=$6,version=version+1 WHERE environment=$1 AND id=$2 AND status='running' AND lease_owner=$3 AND version=$4 AND lease_expires_at>=$6 RETURNING `+backfillColumns, s.Environment, job.ID, s.WorkerID, job.Version, string(encoded), at))
	if errors.Is(err, sql.ErrNoRows) {
		return job, ErrBackfillLease
	}
	if err != nil {
		return job, err
	}
	if err = tx.Commit(); err != nil {
		return job, err
	}
	return next, nil
}
func (s BackfillStore) DiagnosticVerification(ctx context.Context, job BackfillJob, truncated bool, at time.Time) (BackfillJob, error) {
	// Public PDS reads and Jetstream replay cannot prove complete deletes or an
	// authoritative validation watermark. They must retain verification-required.
	if job.SourceMode != "pds_reconciliation" && job.SourceMode != "jetstream_replay" {
		return job, errors.New("diagnostic verification requires a nonauthoritative source")
	}
	tx, err := s.transaction(ctx)
	if err != nil {
		return job, err
	}
	defer tx.Rollback()
	next, err := scanBackfill(tx.QueryRowContext(ctx, `UPDATE appview_backfill_jobs SET verification_status='required',verification_reason='scope_not_exact',scope_truncated=$5,lease_expires_at=$6,updated_at=$7,version=version+1 WHERE environment=$1 AND id=$2 AND status='running' AND lease_owner=$3 AND version=$4 AND lease_expires_at>=$7 RETURNING `+backfillColumns, s.Environment, job.ID, s.WorkerID, job.Version, truncated, at.Add(time.Minute), at))
	if errors.Is(err, sql.ErrNoRows) {
		return job, ErrBackfillLease
	}
	if err != nil {
		return job, err
	}
	if err = tx.Commit(); err != nil {
		return job, err
	}
	return next, nil
}

func recoveryDIDValid(did string) bool {
	if strings.TrimSpace(did) != did {
		return false
	}
	if strings.HasPrefix(did, "did:plc:") {
		id := strings.TrimPrefix(did, "did:plc:")
		if len(id) != 24 {
			return false
		}
		for _, c := range id {
			if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
				return false
			}
		}
		return true
	}
	if !strings.HasPrefix(did, "did:web:") || strings.EqualFold(did, "did:web:skyreader.rss") {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(did, "did:web:"), ":")
	host := parts[0]
	if strings.ContainsAny(host, "%@/\\[]") || thinappviewcore.ValidatePDSBase("https://"+host) == "" {
		return false
	}
	for _, segment := range parts[1:] {
		if segment == "" {
			return false
		}
		for i := 0; i < len(segment); i++ {
			c := segment[i]
			if c == '%' {
				if i+2 >= len(segment) || !recoveryHex(segment[i+1]) || !recoveryHex(segment[i+2]) {
					return false
				}
				i += 2
				continue
			}
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-._~", rune(c))) {
				return false
			}
		}
	}
	return true
}
func recoveryHex(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func (s BackfillStore) RecordFailure(ctx context.Context, job BackfillJob, identityHash, collection, operation string, cursor *int64, category string, at time.Time) error {
	id, err := newSnapshotToken()
	if err != nil {
		return err
	}
	if len(identityHash) != 24 {
		return errors.New("invalid recovery identity hash")
	}
	for _, c := range identityHash {
		if !(c >= 'a' && c <= 'f' || c >= '0' && c <= '9') {
			return errors.New("invalid recovery identity hash")
		}
	}
	if category == "" || len(category) > 64 {
		return errors.New("invalid recovery error category")
	}
	for _, c := range category {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return errors.New("invalid recovery error category")
		}
	}
	collection = string([]rune(collection)[:min(128, len([]rune(collection)))])
	operation = string([]rune(operation)[:min(32, len([]rune(operation)))])
	tx, err := s.transaction(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var owned string
	if err := tx.QueryRowContext(ctx, `SELECT id FROM appview_backfill_jobs WHERE environment=$1 AND id=$2 AND status='running' AND lease_owner=$3 AND version=$4 AND lease_expires_at>=$5 FOR UPDATE`, s.Environment, job.ID, s.WorkerID, job.Version, at).Scan(&owned); errors.Is(err, sql.ErrNoRows) {
		return ErrBackfillLease
	} else if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO appview_recovery_failures(environment,id,job_id,source,record_identifier_hash,collection,operation,cursor,error_type,retry_count,first_failed_at,last_failed_at,expires_at)VALUES($1,$2,$3,'jetstream',$4,$5,$6,$7,$8,0,$9,$9,$10)`, s.Environment, id, job.ID, identityHash, collection, operation, cursor, category, at, at.Add(30*24*time.Hour)); err != nil {
		return err
	}
	return tx.Commit()
}
