package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

const HydrationGeneration = "wire-pds-hydration-v1"

type HydrationJob struct {
	Environment, SourceURI, Generation, RepoDID, Token string
	Sequence                                           int64
	ExpectedCID, SubjectURI, OriginalRevision          sql.NullString
	OriginalTime                                       time.Time
	Attempts                                           int
}

func (j HydrationJob) retryDelay() time.Duration {
	return min(time.Hour, 30*time.Second*time.Duration(1<<min(max(0, j.Attempts-1), 7)))
}

type DependencySeedCursor struct {
	Time       time.Time
	Generation string
	Sequence   int64
}
type DependencyRecoveryStore struct {
	DB          *sql.DB
	Environment string
}

func (s DependencyRecoveryStore) Seed(ctx context.Context, cursor *DependencySeedCursor, at time.Time) (*DependencySeedCursor, error) {
	var afterTime, afterGeneration, afterSequence any
	if cursor != nil {
		afterTime = cursor.Time
		afterGeneration = cursor.Generation
		afterSequence = cursor.Sequence
	}
	row := s.DB.QueryRowContext(ctx, `WITH page AS MATERIALIZED(SELECT environment,source_generation,seq,event_time,source_uri,record_cid,subject_uri FROM wire_recommendation_journal WHERE status='pending' AND environment=$1 AND event_time>$2 AND($3::timestamptz IS NULL OR(event_time,source_generation,seq)>($3,$4,$5)) ORDER BY event_time,source_generation,seq LIMIT 256),seeded AS(INSERT INTO wire_recommendation_dependency_recovery(environment,source_uri,source_generation,seq,expected_cid,subject_uri,next_attempt_at,updated_at) SELECT page.environment,page.source_uri,page.source_generation,page.seq,page.record_cid,page.subject_uri,$6,$6 FROM page JOIN wire_recommendation_record_fences fence ON fence.environment=page.environment AND fence.source_uri=page.source_uri AND fence.source_generation=page.source_generation AND fence.seq=page.seq ON CONFLICT(environment,source_uri)DO UPDATE SET source_generation=EXCLUDED.source_generation,seq=EXCLUDED.seq,expected_cid=EXCLUDED.expected_cid,subject_uri=EXCLUDED.subject_uri,status='pending',next_attempt_at=EXCLUDED.next_attempt_at,lease_token=NULL,lease_expires_at=NULL,verification_token=NULL,staged_document_seq=NULL,staged_publication_seq=NULL,attempt_count=0,updated_at=EXCLUDED.updated_at WHERE(wire_recommendation_dependency_recovery.source_generation,wire_recommendation_dependency_recovery.seq)IS DISTINCT FROM(EXCLUDED.source_generation,EXCLUDED.seq) RETURNING source_uri)SELECT event_time,source_generation,seq FROM page ORDER BY event_time DESC,source_generation DESC,seq DESC LIMIT 1`, s.Environment, at.Add(-wirecore.SignalRetention), afterTime, afterGeneration, afterSequence, at)
	next := &DependencySeedCursor{}
	err := row.Scan(&next.Time, &next.Generation, &next.Sequence)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return next, err
}
func (s DependencyRecoveryStore) Claim(ctx context.Context, at time.Time, limit int) ([]HydrationJob, error) {
	token, err := newGenerationID()
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, `WITH candidates AS MATERIALIZED(SELECT recovery.source_uri,recovery.source_generation,recovery.seq FROM wire_recommendation_dependency_recovery recovery WHERE environment=$1 AND next_attempt_at<=$2 ORDER BY next_attempt_at,source_uri LIMIT $3 FOR UPDATE SKIP LOCKED),current_candidates AS(SELECT candidates.*,COALESCE(journal.status='pending' AND journal.event_time>$4 AND fence.seq IS NOT NULL,FALSE)AS is_current FROM candidates LEFT JOIN wire_recommendation_journal journal ON journal.environment=$1 AND journal.source_generation=candidates.source_generation AND journal.seq=candidates.seq LEFT JOIN wire_recommendation_record_fences fence ON fence.environment=$1 AND fence.source_uri=candidates.source_uri AND fence.source_generation=candidates.source_generation AND fence.seq=candidates.seq),claimed AS(UPDATE wire_recommendation_dependency_recovery recovery SET status=CASE WHEN candidates.is_current THEN 'leased' ELSE 'superseded' END,lease_token=CASE WHEN candidates.is_current THEN $5 ELSE NULL END,lease_expires_at=CASE WHEN candidates.is_current THEN $6::timestamptz ELSE NULL END,next_attempt_at=CASE WHEN candidates.is_current THEN $6::timestamptz ELSE $7::timestamptz END,attempt_count=attempt_count+1,updated_at=$2 FROM current_candidates candidates WHERE recovery.environment=$1 AND recovery.source_uri=candidates.source_uri RETURNING recovery.*)SELECT claimed.environment,claimed.source_uri,claimed.source_generation,claimed.seq,claimed.expected_cid,claimed.subject_uri,journal.repo_did,journal.repo_rev,journal.event_time,claimed.lease_token,claimed.attempt_count FROM claimed JOIN wire_recommendation_journal journal ON journal.environment=claimed.environment AND journal.source_generation=claimed.source_generation AND journal.seq=claimed.seq WHERE claimed.status='leased'`, s.Environment, at, max(1, min(16, limit)), at.Add(-wirecore.SignalRetention), token, at.Add(180*time.Second), distantFuture())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	jobs := []HydrationJob{}
	for rows.Next() {
		var j HydrationJob
		if err = rows.Scan(&j.Environment, &j.SourceURI, &j.Generation, &j.Sequence, &j.ExpectedCID, &j.SubjectURI, &j.RepoDID, &j.OriginalRevision, &j.OriginalTime, &j.Token, &j.Attempts); err != nil {
			return nil, err
		}
		jobs = append(jobs, j)
	}
	return jobs, rows.Err()
}
func (s DependencyRecoveryStore) HasAlias(ctx context.Context, uri string, at time.Time) (bool, error) {
	var exists bool
	err := s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_item_aliases WHERE alias_key=$1 AND expires_at>$2)`, uri, at).Scan(&exists)
	return exists, err
}
func (s DependencyRecoveryStore) current(ctx context.Context, tx *sql.Tx, j HydrationJob, at time.Time, lease bool) (bool, error) {
	for _, key := range []string{"wire-recommendation-account:" + j.Environment + ":" + j.RepoDID, j.SourceURI} {
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, key); err != nil {
			return false, err
		}
	}
	var exists bool
	err := tx.QueryRowContext(ctx, `SELECT TRUE FROM wire_recommendation_dependency_recovery recovery JOIN wire_recommendation_record_fences fence ON fence.environment=recovery.environment AND fence.source_uri=recovery.source_uri AND fence.source_generation=recovery.source_generation AND fence.seq=recovery.seq JOIN wire_recommendation_journal journal ON journal.environment=recovery.environment AND journal.source_generation=recovery.source_generation AND journal.seq=recovery.seq WHERE recovery.environment=$1 AND recovery.source_uri=$2 AND recovery.source_generation=$3 AND recovery.seq=$4 AND journal.status='pending' AND(($5 AND recovery.status='leased' AND recovery.lease_token=$6 AND recovery.lease_expires_at>$7)OR(NOT $5 AND recovery.status='verified' AND recovery.verification_token=$6 AND recovery.valid_until>$7)) AND NOT EXISTS(SELECT 1 FROM wire_recommendation_account_fences account WHERE account.environment=recovery.environment AND account.repo_did=journal.repo_did AND(NOT account.active OR journal.event_time<=account.inactive_through)) FOR UPDATE OF recovery`, j.Environment, j.SourceURI, j.Generation, j.Sequence, lease, j.Token, at).Scan(&exists)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return exists, err
}
func (s DependencyRecoveryStore) Observe(ctx context.Context, j HydrationJob, status string, result PublicRecordVerification, subject, reason *string, at time.Time) (bool, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	current, err := s.current(ctx, tx, j, at, true)
	if err != nil || !current {
		return false, err
	}
	var valid, token any
	next := at.Add(j.retryDelay())
	if status == "verified" {
		observed := result.ObservedAt
		if observed.IsZero() {
			observed = at
		}
		expiry := observed.Add(300 * time.Second)
		valid = expiry
		token = j.Token
		next = expiry
	} else if status == "absent" || status == "changed" || status == "superseded" || status == "unsupported" {
		next = distantFuture()
	}
	var observed any
	if !result.ObservedAt.IsZero() {
		observed = result.ObservedAt
	}
	_, err = tx.ExecContext(ctx, `UPDATE wire_recommendation_dependency_recovery SET status=$1,verified_cid=$2,verified_subject_uri=$3,observed_repo_rev=$4,observed_at=$5,valid_until=$6,verification_token=$7,staged_document_seq=NULL,staged_publication_seq=NULL,next_attempt_at=$8,lease_token=NULL,lease_expires_at=NULL,failure_reason=$9,updated_at=$10 WHERE environment=$11 AND source_uri=$12`, status, nullString(result.CID), subject, nullString(result.Revision), observed, valid, token, next, reason, at, j.Environment, j.SourceURI)
	if err != nil {
		return false, err
	}
	return true, tx.Commit()
}
func (s DependencyRecoveryStore) Postpone(ctx context.Context, j HydrationJob, reason string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE wire_recommendation_dependency_recovery SET status='unavailable',next_attempt_at=$1,lease_token=NULL,lease_expires_at=NULL,failure_reason=$2,updated_at=$3 WHERE environment=$4 AND source_uri=$5 AND((status='leased' AND lease_token=$6 AND lease_expires_at>$3)OR(status='verified' AND verification_token=$6 AND valid_until>$3))AND source_generation=$7 AND seq=$8`, at.Add(j.retryDelay()), reason, at, j.Environment, j.SourceURI, j.Token, j.Generation, j.Sequence)
	return err
}
func (s DependencyRecoveryStore) Wake(ctx context.Context, j HydrationJob, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	current, err := s.current(ctx, tx, j, at, false)
	if err != nil || !current {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE wire_recommendation_journal SET next_attempt_at=$1,updated_at=$1 WHERE environment=$2 AND source_generation=$3 AND seq=$4 AND status='pending' AND next_attempt_at>$1`, at, j.Environment, j.Generation, j.Sequence)
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s DependencyRecoveryStore) Stage(ctx context.Context, records []VerifiedPublicRecord, j HydrationJob, at time.Time) ([]InboxEvent, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	current, err := s.current(ctx, tx, j, at, false)
	if err != nil || !current {
		return nil, err
	}
	var staged sql.NullInt64
	if err = tx.QueryRowContext(ctx, `SELECT staged_document_seq FROM wire_recommendation_dependency_recovery WHERE environment=$1 AND source_uri=$2`, j.Environment, j.SourceURI).Scan(&staged); err != nil {
		return nil, err
	}
	if staged.Valid {
		return nil, nil
	}
	events := []InboxEvent{}
	var document, publication any
	for _, record := range records {
		if record.Collection != "site.standard.document" && record.Collection != "site.standard.entry" && record.Collection != "site.standard.publication" {
			return nil, errors.New("invalid hydration record")
		}
		var value map[string]any
		if err = json.Unmarshal(record.Record, &value); err != nil || value == nil {
			return nil, errors.New("invalid hydration record")
		}
		payload, err := json.Marshal(map[string]any{"snapshot": map[string]any{"record": value, "cid": record.CID, "rev": record.Revision}})
		if err != nil {
			return nil, err
		}
		var seq int64
		if err = tx.QueryRowContext(ctx, `SELECT nextval('wire_pds_hydration_sequence')`).Scan(&seq); err != nil {
			return nil, err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO wire_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,operation,record_key,record_cid,repo_rev,payload,event_time,status,lease_owner,lease_token,lease_expires_at,next_attempt_at,attempt_count)VALUES($1,$2,$3,$4,'pds_record_snapshot','snapshot',$5,$6,'update',$7,$8,$9,$10::jsonb,$11,'leased','wire-dependency-recovery',$12,$13,$14,1)`, s.Environment, HydrationGeneration, seq, record.PDSBase, record.RepoDID, record.Collection, record.RecordKey, record.CID, record.Revision, string(payload), record.ObservedAt, j.Token, at.Add(120*time.Second), at)
		if err != nil {
			return nil, err
		}
		events = append(events, InboxEvent{Repository: InboxRepository{Environment: s.Environment, SourceGeneration: HydrationGeneration, RepoDID: record.RepoDID}, Sequence: seq, SourceHost: record.PDSBase, CursorKind: "pds_record_snapshot", EventKind: "snapshot", Collection: nullString(record.Collection), Operation: nullString("update"), RecordKey: nullString(record.RecordKey), PayloadJSON: string(payload), EventTime: record.ObservedAt, LeaseToken: j.Token, AttemptCount: 1})
		if record.Collection == "site.standard.publication" {
			if publication == nil {
				publication = seq
			}
		} else {
			document = seq
		}
	}
	if len(events) > 0 {
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_ingestion_admission(environment,retained_rows,updated_at)VALUES($1,$2,$3)ON CONFLICT(environment)DO UPDATE SET retained_rows=wire_ingestion_admission.retained_rows+EXCLUDED.retained_rows,updated_at=EXCLUDED.updated_at`, s.Environment, len(events), at); err != nil {
			return nil, err
		}
	}
	_, err = tx.ExecContext(ctx, `UPDATE wire_recommendation_dependency_recovery SET staged_document_seq=$1,staged_publication_seq=$2,updated_at=$3 WHERE environment=$4 AND source_uri=$5`, document, publication, at, j.Environment, j.SourceURI)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return events, nil
}

func distantFuture() time.Time { return time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC) }
