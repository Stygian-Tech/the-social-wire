package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

var ErrLeaseUnavailable = errors.New("ingestion leader lease is held by another process")
var ErrWireAdmissionPaused = errors.New("Wire inbox admission paused at configured capacity")

const wireRecoveryAnchorRetention = 7 * 24 * time.Hour

type WireCapacityExceededError struct {
	InboxRows, InboxMaxRows, DatabaseBytes, DatabaseMaxBytes int64
}

func (e *WireCapacityExceededError) Error() string {
	return fmt.Sprintf(
		"%v: inbox=%d/%d rows database=%d/%d bytes",
		ErrWireAdmissionPaused, e.InboxRows, e.InboxMaxRows, e.DatabaseBytes, e.DatabaseMaxBytes,
	)
}

func (e *WireCapacityExceededError) Unwrap() error { return ErrWireAdmissionPaused }

type Postgres struct {
	db                   *sql.DB
	source               ingest.SourceIdentity
	wireInboxMaxRows     int64
	wireDatabaseMaxBytes int64
}

type ReplayProgress struct {
	State            string
	AfterSeq         uint64
	BeforeSeq        uint64
	SealedSeq        uint64
	BytesDownloaded  int64
	RetryCount       int
	RangeResumeCount int
	ETag             string
	LastProgressAt   time.Time
}

func Open(ctx context.Context, databaseURL string, source ingest.SourceIdentity) (*Postgres, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open PostgreSQL: %w", err)
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)
	db.SetConnMaxLifetime(30 * time.Minute)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping PostgreSQL: %w", err)
	}
	return &Postgres{db: db, source: source}, nil
}

func New(db *sql.DB, source ingest.SourceIdentity) *Postgres {
	return &Postgres{db: db, source: source}
}

func (p *Postgres) Close() error { return p.db.Close() }

func (p *Postgres) Ping(ctx context.Context) error { return p.db.PingContext(ctx) }

func (p *Postgres) ConfigureWireAdmission(inboxMaxRows, databaseMaxBytes int64) {
	p.wireInboxMaxRows = inboxMaxRows
	p.wireDatabaseMaxBytes = databaseMaxBytes
}

func (p *Postgres) ReconcileWireAdmission(ctx context.Context, lease Lease) (bool, error) {
	if !p.source.IsWire() {
		return false, nil
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return false, fmt.Errorf("begin Wire admission reconciliation: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var leaseValid bool
	if err := tx.QueryRowContext(ctx, `
		SELECT TRUE
		FROM appview_ingestion_leases
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL
		  AND lease_expires_at > NOW()
		FOR SHARE`, p.source.Environment, lease.Name, p.source.Generation,
		lease.OwnerID, lease.FencingToken).Scan(&leaseValid); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, ErrLeaseUnavailable
		}
		return false, fmt.Errorf("verify Wire recovery fencing token: %w", err)
	}
	if !leaseValid {
		return false, ErrLeaseUnavailable
	}
	var ignored int64
	if err := tx.QueryRowContext(ctx, `
		SELECT retained_rows FROM wire_ingestion_admission
		WHERE environment = $1 FOR UPDATE`, p.source.Environment).Scan(&ignored); err != nil {
		return false, fmt.Errorf("lock Wire admission counter: %w", err)
	}
	var epochCreated bool
	if err := tx.QueryRowContext(ctx, `
		WITH inserted AS (
		  INSERT INTO wire_ingestion_inbox_epochs
		    (environment, source_generation, initialized_at)
		  VALUES ($1, $2, NOW())
		  ON CONFLICT (environment, source_generation) DO NOTHING
		  RETURNING TRUE
		)
		SELECT EXISTS(SELECT 1 FROM inserted)`,
		p.source.Environment, p.source.Generation).Scan(&epochCreated); err != nil {
		return false, fmt.Errorf("inspect Wire inbox crash epoch: %w", err)
	}

	recovered := false
	if epochCreated {
		var checkpointExists bool
		if err := tx.QueryRowContext(ctx, `
			SELECT EXISTS(
			  SELECT 1 FROM appview_jetstream_checkpoints
			  WHERE environment = $1 AND source_generation = $2
			)`, p.source.Environment, p.source.Generation).Scan(&checkpointExists); err != nil {
			return false, fmt.Errorf("inspect Wire recovery checkpoint: %w", err)
		}
		if checkpointExists {
			var recoverySeq int64
			var recoveryEventTime time.Time
			if err := tx.QueryRowContext(ctx, `
				SELECT checkpoint_seq, checkpoint_event_time
				FROM wire_ingestion_recovery_anchors
				WHERE environment = $1 AND source_generation = $2
				ORDER BY checkpoint_seq, anchor_bucket
				LIMIT 1`, p.source.Environment, p.source.Generation).
				Scan(&recoverySeq, &recoveryEventTime); err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					return false, errors.New("Wire inbox crash detected without a recovery anchor")
				}
				return false, fmt.Errorf("load Wire recovery anchor: %w", err)
			}
			result, updateErr := tx.ExecContext(ctx, `
				UPDATE appview_jetstream_checkpoints
				SET last_staged_seq = $3,
				    last_staged_event_at = $4,
				    last_staged_at = NOW(),
				    replay_state = 'replaying',
				    updated_at = NOW()
				WHERE environment = $1 AND source_generation = $2
				  AND source_host = $5 AND stream_nsid = $6
				  AND filter_fingerprint = $7 AND cursor_kind = $8`,
				p.source.Environment, p.source.Generation, recoverySeq, recoveryEventTime,
				p.source.Host, p.source.StreamNSID, p.source.FilterFingerprint, p.source.CursorKind)
			if updateErr != nil {
				return false, fmt.Errorf("rewind Wire crash recovery cursor: %w", updateErr)
			}
			rows, rowsErr := result.RowsAffected()
			if rowsErr != nil {
				return false, fmt.Errorf("inspect Wire recovery rewind: %w", rowsErr)
			}
			if rows != 1 {
				return false, errors.New("Wire recovery checkpoint identity mismatch")
			}
			recovered = true
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wire_ingestion_admission
		SET retained_rows = (
		  SELECT COUNT(*) FROM wire_ingestion_inbox WHERE environment = $1
		), updated_at = NOW()
		WHERE environment = $1`, p.source.Environment); err != nil {
		return false, fmt.Errorf("reconcile Wire admission counter: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit Wire admission reconciliation: %w", err)
	}
	return recovered, nil
}

func (p *Postgres) LoadCheckpoint(ctx context.Context) (*ingest.Checkpoint, error) {
	row := p.db.QueryRowContext(ctx, `
		SELECT source_host, stream_nsid, filter_fingerprint, cursor_kind,
		       last_staged_seq, replay_bytes_downloaded, replay_state,
		       replay_after_seq, replay_before_seq, replay_sealed_seq,
		       replay_retry_count, replay_range_resume_count, COALESCE(replay_etag, ''),
		       last_staged_at, replay_last_progress_at
		FROM appview_jetstream_checkpoints
		WHERE environment = $1 AND source_generation = $2`,
		p.source.Environment, p.source.Generation)
	var checkpoint ingest.Checkpoint
	var seq, replayAfterSeq, replayBeforeSeq, replaySealedSeq sql.NullInt64
	var lastStagedAt sql.NullTime
	var replayLastProgressAt sql.NullTime
	if err := row.Scan(&checkpoint.Host, &checkpoint.StreamNSID, &checkpoint.FilterFingerprint,
		&checkpoint.CursorKind, &seq, &checkpoint.ReplayBytesDownloaded, &checkpoint.ReplayState,
		&replayAfterSeq, &replayBeforeSeq, &replaySealedSeq,
		&checkpoint.ReplayRetryCount, &checkpoint.ReplayRangeResumeCount, &checkpoint.ReplayETag,
		&lastStagedAt, &replayLastProgressAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("load Jetstream checkpoint: %w", err)
	}
	var cursorErr error
	if checkpoint.LastStagedSeq, cursorErr = cursorPointer(seq, "Jetstream cursor"); cursorErr != nil {
		return nil, cursorErr
	}
	if checkpoint.ReplayAfterSeq, cursorErr = cursorPointer(replayAfterSeq, "replay lower bound"); cursorErr != nil {
		return nil, cursorErr
	}
	if checkpoint.ReplayBeforeSeq, cursorErr = cursorPointer(replayBeforeSeq, "replay upper bound"); cursorErr != nil {
		return nil, cursorErr
	}
	if checkpoint.ReplaySealedSeq, cursorErr = cursorPointer(replaySealedSeq, "replay sealed bound"); cursorErr != nil {
		return nil, cursorErr
	}
	if lastStagedAt.Valid {
		checkpoint.LastStagedAt = lastStagedAt.Time
	}
	if replayLastProgressAt.Valid {
		checkpoint.ReplayLastProgressAt = replayLastProgressAt.Time
	}
	if err := p.source.ValidateCheckpoint(checkpoint); err != nil {
		return nil, err
	}
	return &checkpoint, nil
}

func (p *Postgres) ReplayUsageBuckets(ctx context.Context) ([]ingest.ReplayUsageBucket, error) {
	rows, err := p.db.QueryContext(ctx, `
		SELECT bucket_started_at, bytes_downloaded
		FROM appview_ingestion_replay_usage
		WHERE environment = $1 AND source_generation = $2
		  AND bucket_started_at > NOW() - INTERVAL '24 hours'
		ORDER BY bucket_started_at`, p.source.Environment, p.source.Generation)
	if err != nil {
		return nil, fmt.Errorf("query durable replay usage: %w", err)
	}
	defer rows.Close()
	var buckets []ingest.ReplayUsageBucket
	for rows.Next() {
		var bucket ingest.ReplayUsageBucket
		if err := rows.Scan(&bucket.StartedAt, &bucket.Bytes); err != nil {
			return nil, fmt.Errorf("scan durable replay usage: %w", err)
		}
		buckets = append(buckets, bucket)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate durable replay usage: %w", err)
	}
	return buckets, nil
}

func (p *Postgres) RecordReplayBytes(ctx context.Context, bytes int64) error {
	if bytes <= 0 {
		return nil
	}
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO appview_ingestion_replay_usage
		  (environment, source_generation, bucket_started_at, bytes_downloaded, updated_at)
		VALUES ($1, $2, date_trunc('minute', NOW()), $3, NOW())
		ON CONFLICT (environment, source_generation, bucket_started_at) DO UPDATE SET
		  bytes_downloaded = appview_ingestion_replay_usage.bytes_downloaded + EXCLUDED.bytes_downloaded,
		  updated_at = NOW()`, p.source.Environment, p.source.Generation, bytes)
	if err != nil {
		return fmt.Errorf("record durable replay usage: %w", err)
	}
	return nil
}

func (p *Postgres) PruneReplayUsage(ctx context.Context) error {
	_, err := p.db.ExecContext(ctx, `
		DELETE FROM appview_ingestion_replay_usage
		WHERE environment = $1 AND source_generation = $2
		  AND bucket_started_at <= NOW() - INTERVAL '48 hours'`,
		p.source.Environment, p.source.Generation)
	if err != nil {
		return fmt.Errorf("prune durable replay usage: %w", err)
	}
	return nil
}

func (p *Postgres) UpdateReplayState(ctx context.Context, lease Lease, progress ReplayProgress) error {
	result, err := p.db.ExecContext(ctx, `
		UPDATE appview_jetstream_checkpoints checkpoint
		SET replay_state = $6, replay_bytes_downloaded = $7,
		    replay_retry_count = $8, replay_range_resume_count = $9,
		    replay_etag = $10, updated_at = NOW()
		WHERE checkpoint.environment = $1 AND checkpoint.source_generation = $2
		  AND EXISTS (
		    SELECT 1 FROM appview_ingestion_leases lease
		    WHERE lease.environment = $1 AND lease.lease_name = $3
		      AND lease.source_generation = $2 AND lease.owner_id = $4
		      AND lease.fencing_token = $5 AND lease.released_at IS NULL
		      AND lease.lease_expires_at > NOW()
		  )`, p.source.Environment, p.source.Generation, lease.Name, lease.OwnerID,
		lease.FencingToken, progress.State, progress.BytesDownloaded, progress.RetryCount,
		progress.RangeResumeCount, nullableString(progress.ETag))
	if err != nil {
		return fmt.Errorf("update replay state: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect replay state update: %w", err)
	}
	if rows == 0 {
		return nil
	}
	return nil
}

type IncidentSignal struct {
	Category         string
	StartCursor      uint64
	EndCursor        uint64
	LastError        string
	ReplayState      string
	BytesDownloaded  int64
	RetryCount       int
	RangeResumeCount int
	SealedSeq        uint64
}

func (p *Postgres) UpsertIncident(ctx context.Context, signal IncidentSignal) error {
	if signal.Category == "" {
		return errors.New("incident category is required")
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin incident merge: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	lockKey := p.source.Environment + "|" + p.source.Generation + "|" + p.source.Host + "|" + signal.Category
	if _, err := tx.ExecContext(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", lockKey); err != nil {
		return fmt.Errorf("lock incident merge: %w", err)
	}
	var incidentID string
	err = tx.QueryRowContext(ctx, `
		SELECT id
		FROM appview_ingestion_incidents
		WHERE environment = $1 AND source_generation = $2 AND source_host = $3
		  AND source = 'jetstream-v2' AND cursor_kind = $4 AND category = $5
		  AND status IN ('open', 'recovering', 'verification_required')
		ORDER BY last_detected_at DESC, id DESC
		LIMIT 1
		FOR UPDATE`, p.source.Environment, p.source.Generation, p.source.Host,
		p.source.CursorKind, signal.Category).
		Scan(&incidentID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("find active incident: %w", err)
	}
	if errors.Is(err, sql.ErrNoRows) {
		incidentID, err = newIncidentID()
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `
			INSERT INTO appview_ingestion_incidents
			  (environment, id, source_generation, source_host, source, cursor_kind, start_cursor,
			   end_cursor, category, status, occurrence_count, first_detected_at,
			   last_detected_at, last_error, replay_state, replay_bytes_downloaded,
			   replay_retry_count, replay_range_resume_count, replay_sealed_seq,
			   verification_evidence, updated_at)
			VALUES ($1, $2, $3, $4, 'jetstream-v2', $5, $6, $7, $8, 'open', 1,
			        NOW(), NOW(), $9, $10, $11, $12, $13, $14, '{}'::jsonb, NOW())`,
			p.source.Environment, incidentID, p.source.Generation, p.source.Host, p.source.CursorKind,
			nullableCursor(signal.StartCursor), nullableCursor(signal.EndCursor), signal.Category,
			nullableString(signal.LastError), nullableString(signal.ReplayState), signal.BytesDownloaded,
			signal.RetryCount, signal.RangeResumeCount, nullableCursor(signal.SealedSeq))
		if err != nil {
			return fmt.Errorf("insert ingestion incident: %w", err)
		}
	} else {
		_, err = tx.ExecContext(ctx, `
			UPDATE appview_ingestion_incidents
			SET occurrence_count = occurrence_count + 1,
			    start_cursor = COALESCE(start_cursor, $3),
			    end_cursor = GREATEST(COALESCE(end_cursor, $4), $4),
			    last_detected_at = NOW(), last_error = $5, replay_state = $6,
			    replay_bytes_downloaded = GREATEST(replay_bytes_downloaded, $7),
			    replay_retry_count = GREATEST(replay_retry_count, $8),
			    replay_range_resume_count = GREATEST(replay_range_resume_count, $9),
			    replay_sealed_seq = GREATEST(COALESCE(replay_sealed_seq, $10), $10),
			    updated_at = NOW(), version = version + 1
			WHERE environment = $1 AND id = $2`, p.source.Environment, incidentID,
			nullableCursor(signal.StartCursor), nullableCursor(signal.EndCursor),
			nullableString(signal.LastError), nullableString(signal.ReplayState), signal.BytesDownloaded,
			signal.RetryCount, signal.RangeResumeCount, nullableCursor(signal.SealedSeq))
		if err != nil {
			return fmt.Errorf("update ingestion incident: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit incident merge: %w", err)
	}
	return nil
}

func nullableCursor(value uint64) any {
	if value == 0 {
		return nil
	}
	return int64(value)
}

func cursorPointer(value sql.NullInt64, description string) (*uint64, error) {
	if !value.Valid {
		return nil, nil
	}
	if value.Int64 < 0 {
		return nil, fmt.Errorf("stored %s is negative: %d", description, value.Int64)
	}
	cursor := uint64(value.Int64)
	return &cursor, nil
}

func newIncidentID() (string, error) {
	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		return "", fmt.Errorf("generate incident ID: %w", err)
	}
	return "jsv2-" + hex.EncodeToString(random), nil
}

func (p *Postgres) StageBatch(ctx context.Context, lease Lease, events []ingest.InboxEvent, checkpointSeq uint64, checkpointEventTime time.Time, progress ReplayProgress) error {
	if checkpointSeq == 0 {
		return errors.New("cannot stage a zero Jetstream checkpoint")
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin stage batch: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var leaseValid bool
	if err := tx.QueryRowContext(ctx, `
		SELECT TRUE
		FROM appview_ingestion_leases
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL
		  AND lease_expires_at > NOW()
		FOR SHARE`, p.source.Environment, lease.Name, p.source.Generation,
		lease.OwnerID, lease.FencingToken).Scan(&leaseValid); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseUnavailable
		}
		return fmt.Errorf("verify ingestion fencing token: %w", err)
	}
	if !leaseValid {
		return ErrLeaseUnavailable
	}
	var admittedWireEvents int64
	var wireInboxRows int64
	var wireDatabaseBytes int64
	if p.source.IsWire() && p.wireInboxMaxRows > 0 && p.wireDatabaseMaxBytes > 0 {
		if err := tx.QueryRowContext(ctx, `
			SELECT retained_rows, pg_database_size(current_database())
			FROM wire_ingestion_admission
			WHERE environment = $1
			FOR UPDATE`, p.source.Environment).Scan(&wireInboxRows, &wireDatabaseBytes); err != nil {
			return fmt.Errorf("measure Wire admission capacity: %w", err)
		}
		if wireDatabaseBytes >= p.wireDatabaseMaxBytes {
			return &WireCapacityExceededError{
				InboxRows: wireInboxRows, InboxMaxRows: p.wireInboxMaxRows,
				DatabaseBytes: wireDatabaseBytes, DatabaseMaxBytes: p.wireDatabaseMaxBytes,
			}
		}
	}

	for _, event := range events {
		if p.source.IsWire() {
			inserted, err := p.stageWireInboxEvent(ctx, tx, event)
			if err != nil {
				return err
			}
			if inserted {
				admittedWireEvents++
			}
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO appview_ingestion_inbox
			  (environment, source_generation, seq, source_host, cursor_kind,
			   event_kind, repo_did, collection, operation, repo_rev, record_key,
			   record_cid, payload, event_time, status, attempt_count,
			   next_attempt_at, staged_at)
			SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
			       $13::jsonb, $14, 'pending', 0, NOW(), NOW()
			WHERE $8::text IS NULL
			   OR (
			     $8::text IN (
			       'site.standard.document', 'site.standard.entry',
			       'com.standard.document', 'com.standard.entry'
			     )
			     AND EXISTS (
			       SELECT 1 FROM appview_publication_scopes scope
			       WHERE scope.author_did = $7
			     )
			   )
			   OR (
			     $8::text IN (
			       'app.skyreader.feed.subscription',
			       'site.standard.graph.subscription'
			     )
			     AND (
			       EXISTS (
			         SELECT 1 FROM appview_viewer_feeds feed
			         WHERE feed.viewer_did = $7
			       )
			       OR EXISTS (
			         SELECT 1 FROM appview_publication_scopes scope
			         WHERE scope.viewer_did = $7
			       )
			     )
			   )
			ON CONFLICT (environment, source_generation, seq) DO NOTHING`,
			p.source.Environment, p.source.Generation, int64(event.Seq), p.source.Host,
			p.source.CursorKind, event.Kind, event.RepoDID, event.Collection, event.Operation,
			event.RepoRev, event.RecordKey, event.RecordCID, string(event.Payload), event.Time,
		); err != nil {
			return fmt.Errorf("insert inbox event %d: %w", event.Seq, err)
		}
	}
	if p.source.IsWire() && p.wireInboxMaxRows > 0 && wireInboxRows+admittedWireEvents > p.wireInboxMaxRows {
		return &WireCapacityExceededError{
			InboxRows: wireInboxRows, InboxMaxRows: p.wireInboxMaxRows,
			DatabaseBytes: wireDatabaseBytes, DatabaseMaxBytes: p.wireDatabaseMaxBytes,
		}
	}
	if admittedWireEvents > 0 {
		if _, err := tx.ExecContext(ctx, `
			UPDATE wire_ingestion_admission
			SET retained_rows = retained_rows + $2, updated_at = NOW()
			WHERE environment = $1`, p.source.Environment, admittedWireEvents); err != nil {
			return fmt.Errorf("update Wire admission count: %w", err)
		}
	}
	if p.source.IsWire() {
		if _, err := tx.ExecContext(ctx, `
			WITH upserted AS (
			  INSERT INTO wire_ingestion_recovery_anchors
			    (environment, source_generation, anchor_bucket, checkpoint_seq,
			     checkpoint_event_time, captured_at)
			  VALUES ($1, $2, date_trunc('hour', NOW()), $3, $4, NOW())
			  ON CONFLICT (environment, source_generation, anchor_bucket) DO UPDATE
			  SET checkpoint_seq = LEAST(
			        wire_ingestion_recovery_anchors.checkpoint_seq,
			        EXCLUDED.checkpoint_seq
			      ),
			      checkpoint_event_time = LEAST(
			        wire_ingestion_recovery_anchors.checkpoint_event_time,
			        EXCLUDED.checkpoint_event_time
			      ),
			      captured_at = LEAST(
			        wire_ingestion_recovery_anchors.captured_at,
			        EXCLUDED.captured_at
			      )
			  RETURNING anchor_bucket
			), boundary AS (
			  SELECT MAX(captured_at) AS captured_at
			  FROM wire_ingestion_recovery_anchors
			  WHERE environment = $1 AND source_generation = $2
			    AND captured_at <= NOW() - $5::interval
			)
			DELETE FROM wire_ingestion_recovery_anchors anchor
			USING boundary
			WHERE anchor.environment = $1 AND anchor.source_generation = $2
			  AND boundary.captured_at IS NOT NULL
			  AND anchor.captured_at < boundary.captured_at`,
			p.source.Environment, p.source.Generation, int64(checkpointSeq), checkpointEventTime,
			fmt.Sprintf("%d seconds", int64(wireRecoveryAnchorRetention.Seconds()))); err != nil {
			return fmt.Errorf("journal Wire recovery anchor: %w", err)
		}
	}

	result, err := tx.ExecContext(ctx, `
		INSERT INTO appview_jetstream_checkpoints
		  (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
		   cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
		   replay_state, replay_after_seq, replay_before_seq, replay_sealed_seq, replay_bytes_downloaded,
		   replay_retry_count, replay_range_resume_count, replay_etag,
		   replay_last_progress_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), $9, $10, $11, $12, $13, $14, $15, $16, $17, NOW())
		ON CONFLICT (environment, source_generation) DO UPDATE SET
		  last_staged_seq = GREATEST(appview_jetstream_checkpoints.last_staged_seq, EXCLUDED.last_staged_seq),
		  last_staged_event_at = CASE
		    WHEN appview_jetstream_checkpoints.last_staged_seq IS NULL
		      OR EXCLUDED.last_staged_seq >= appview_jetstream_checkpoints.last_staged_seq
		    THEN EXCLUDED.last_staged_event_at ELSE appview_jetstream_checkpoints.last_staged_event_at END,
		  last_staged_at = CASE
		    WHEN appview_jetstream_checkpoints.last_staged_seq IS NULL
		      OR EXCLUDED.last_staged_seq > appview_jetstream_checkpoints.last_staged_seq
		    THEN NOW() ELSE appview_jetstream_checkpoints.last_staged_at END,
		  replay_state = EXCLUDED.replay_state,
		  replay_after_seq = EXCLUDED.replay_after_seq,
		  replay_before_seq = EXCLUDED.replay_before_seq,
		  replay_sealed_seq = EXCLUDED.replay_sealed_seq,
		  replay_bytes_downloaded = EXCLUDED.replay_bytes_downloaded,
		  replay_retry_count = EXCLUDED.replay_retry_count,
		  replay_range_resume_count = EXCLUDED.replay_range_resume_count,
		  replay_etag = EXCLUDED.replay_etag,
		  replay_last_progress_at = CASE
		    WHEN appview_jetstream_checkpoints.last_staged_seq IS NULL
		      OR EXCLUDED.last_staged_seq > appview_jetstream_checkpoints.last_staged_seq
		    THEN EXCLUDED.replay_last_progress_at
		    ELSE appview_jetstream_checkpoints.replay_last_progress_at END,
		  updated_at = NOW()
		WHERE appview_jetstream_checkpoints.source_host = EXCLUDED.source_host
		  AND appview_jetstream_checkpoints.stream_nsid = EXCLUDED.stream_nsid
		  AND appview_jetstream_checkpoints.filter_fingerprint = EXCLUDED.filter_fingerprint
		  AND appview_jetstream_checkpoints.cursor_kind = EXCLUDED.cursor_kind
		  AND appview_jetstream_checkpoints.replay_state <> 'snapshot_complete'
		  AND (
		    EXCLUDED.replay_before_seq IS NULL
		    OR (
		      appview_jetstream_checkpoints.replay_after_seq = EXCLUDED.replay_after_seq
		      AND appview_jetstream_checkpoints.replay_before_seq = EXCLUDED.replay_before_seq
		    )
		  )`,
		p.source.Environment, p.source.Generation, p.source.Host, p.source.StreamNSID,
		p.source.FilterFingerprint, p.source.CursorKind, int64(checkpointSeq), checkpointEventTime,
		progress.State, int64(progress.AfterSeq), nullableCursor(progress.BeforeSeq), int64(progress.SealedSeq),
		progress.BytesDownloaded, progress.RetryCount, progress.RangeResumeCount,
		nullableString(progress.ETag), progress.LastProgressAt,
	)
	if err != nil {
		return fmt.Errorf("advance Jetstream checkpoint: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect checkpoint advance: %w", err)
	}
	if rows != 1 {
		return errors.New("checkpoint source identity or immutable replay range mismatch")
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit stage batch: %w", err)
	}
	return nil
}

// EnsureSnapshotRange binds a dedicated source generation to one immutable replay window before
// any archive request starts, including ranges where no event will match the collection filter.
func (p *Postgres) EnsureSnapshotRange(
	ctx context.Context,
	lease Lease,
	afterSeq uint64,
	beforeSeq uint64,
) error {
	if beforeSeq == 0 || afterSeq >= beforeSeq {
		return errors.New("invalid bounded snapshot range")
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin snapshot range binding: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var leaseValid bool
	if err := tx.QueryRowContext(ctx, `
		SELECT TRUE
		FROM appview_ingestion_leases
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL
		  AND lease_expires_at > NOW()
		FOR SHARE`, p.source.Environment, lease.Name, p.source.Generation,
		lease.OwnerID, lease.FencingToken).Scan(&leaseValid); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseUnavailable
		}
		return fmt.Errorf("verify snapshot range fencing token: %w", err)
	}

	result, err := tx.ExecContext(ctx, `
		INSERT INTO appview_jetstream_checkpoints
		  (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
		   cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
		   replay_state, replay_after_seq, replay_before_seq, replay_sealed_seq,
		   replay_bytes_downloaded, replay_retry_count, replay_range_resume_count,
		   replay_etag, replay_last_progress_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, NULL, NULL, NULL,
		        'replaying', $7, $8, NULL, 0, 0, 0, NULL, NOW(), NOW())
		ON CONFLICT (environment, source_generation) DO UPDATE SET
		  updated_at = appview_jetstream_checkpoints.updated_at
		WHERE appview_jetstream_checkpoints.source_host = EXCLUDED.source_host
		  AND appview_jetstream_checkpoints.stream_nsid = EXCLUDED.stream_nsid
		  AND appview_jetstream_checkpoints.filter_fingerprint = EXCLUDED.filter_fingerprint
		  AND appview_jetstream_checkpoints.cursor_kind = EXCLUDED.cursor_kind
		  AND appview_jetstream_checkpoints.replay_after_seq = EXCLUDED.replay_after_seq
		  AND appview_jetstream_checkpoints.replay_before_seq = EXCLUDED.replay_before_seq
		  AND appview_jetstream_checkpoints.replay_state IN ('idle', 'replaying', 'paused_budget', 'failed')`,
		p.source.Environment, p.source.Generation, p.source.Host, p.source.StreamNSID,
		p.source.FilterFingerprint, p.source.CursorKind, int64(afterSeq), int64(beforeSeq),
	)
	if err != nil {
		return fmt.Errorf("bind bounded snapshot range: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect bounded snapshot range binding: %w", err)
	}
	if rows != 1 {
		return errors.New("snapshot source identity, state, or immutable range mismatch")
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit bounded snapshot range binding: %w", err)
	}
	return nil
}

// CompleteSnapshot durably records that the configured bounded archive range was fully scanned.
// last_staged_seq remains the highest matching event when one exists and stays NULL when none did.
func (p *Postgres) CompleteSnapshot(
	ctx context.Context,
	lease Lease,
	afterSeq uint64,
	beforeSeq uint64,
	progress ReplayProgress,
) error {
	if beforeSeq == 0 || afterSeq >= beforeSeq || progress.SealedSeq != beforeSeq {
		return errors.New("invalid bounded snapshot completion range")
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin snapshot completion: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var leaseValid bool
	if err := tx.QueryRowContext(ctx, `
		SELECT TRUE
		FROM appview_ingestion_leases
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL
		  AND lease_expires_at > NOW()
		FOR SHARE`, p.source.Environment, lease.Name, p.source.Generation,
		lease.OwnerID, lease.FencingToken).Scan(&leaseValid); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseUnavailable
		}
		return fmt.Errorf("verify snapshot completion fencing token: %w", err)
	}

	result, err := tx.ExecContext(ctx, `
		INSERT INTO appview_jetstream_checkpoints
		  (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
		   cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
		   replay_state, replay_after_seq, replay_before_seq, replay_sealed_seq, replay_bytes_downloaded,
		   replay_retry_count, replay_range_resume_count, replay_etag,
		   replay_last_progress_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, NULL, NULL, NULL,
		        'snapshot_complete', $7, $8, $9, $10, $11, $12, $13, NOW(), NOW())
		ON CONFLICT (environment, source_generation) DO UPDATE SET
		  replay_state = 'snapshot_complete',
		  replay_sealed_seq = EXCLUDED.replay_sealed_seq,
		  replay_bytes_downloaded = EXCLUDED.replay_bytes_downloaded,
		  replay_retry_count = EXCLUDED.replay_retry_count,
		  replay_range_resume_count = EXCLUDED.replay_range_resume_count,
		  replay_etag = EXCLUDED.replay_etag,
		  replay_last_progress_at = NOW(), updated_at = NOW()
		WHERE appview_jetstream_checkpoints.source_host = EXCLUDED.source_host
		  AND appview_jetstream_checkpoints.stream_nsid = EXCLUDED.stream_nsid
		  AND appview_jetstream_checkpoints.filter_fingerprint = EXCLUDED.filter_fingerprint
		  AND appview_jetstream_checkpoints.cursor_kind = EXCLUDED.cursor_kind
		  AND appview_jetstream_checkpoints.replay_after_seq = EXCLUDED.replay_after_seq
		  AND appview_jetstream_checkpoints.replay_before_seq = EXCLUDED.replay_before_seq
		  AND (
		    appview_jetstream_checkpoints.last_staged_seq IS NULL
		    OR appview_jetstream_checkpoints.last_staged_seq <= EXCLUDED.replay_before_seq
		  )`,
		p.source.Environment, p.source.Generation, p.source.Host, p.source.StreamNSID,
		p.source.FilterFingerprint, p.source.CursorKind, int64(afterSeq), int64(beforeSeq),
		int64(progress.SealedSeq), progress.BytesDownloaded, progress.RetryCount,
		progress.RangeResumeCount, nullableString(progress.ETag),
	)
	if err != nil {
		return fmt.Errorf("persist bounded snapshot completion: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect bounded snapshot completion: %w", err)
	}
	if rows != 1 {
		return errors.New("snapshot completion source identity or range mismatch")
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit bounded snapshot completion: %w", err)
	}
	return nil
}

func (p *Postgres) stageWireInboxEvent(
	ctx context.Context,
	tx *sql.Tx,
	event ingest.InboxEvent,
) (bool, error) {
	payload := wireJSONPayloadForPostgres(event.Payload)
	result, err := tx.ExecContext(ctx, `
		INSERT INTO wire_ingestion_inbox
		  (environment, source_generation, seq, source_host, cursor_kind,
		   event_kind, repo_did, collection, operation, repo_rev, record_key,
		   record_cid, payload, event_time, status, attempt_count,
		   next_attempt_at, staged_at, updated_at, expires_at)
		SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
		       $13::jsonb, $14, 'pending', 0, NOW(), NOW(), NOW(), 'infinity'::timestamptz
		WHERE COALESCE(NOT (
		  $8::text IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
		  AND $9::text IN ('create', 'update')
		), TRUE) OR EXISTS (
		  SELECT 1
		  FROM wire_item_aliases alias
		  WHERE alias.alias_key = $13::jsonb #>> '{commit,record,subject,uri}'
		    AND alias.expires_at > NOW()
		)
		ON CONFLICT (environment, source_generation, seq) DO NOTHING`,
		p.source.Environment, p.source.Generation, int64(event.Seq), p.source.Host,
		p.source.CursorKind, event.Kind, event.RepoDID, event.Collection, event.Operation,
		event.RepoRev, event.RecordKey, event.RecordCID, string(payload), event.Time,
	)
	if err != nil {
		return false, fmt.Errorf("insert Wire inbox event %d: %w", event.Seq, err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("inspect Wire inbox insert %d: %w", event.Seq, err)
	}
	return rows == 1, nil
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func (p *Postgres) TrackedDIDs(ctx context.Context) (map[string]struct{}, error) {
	rows, err := p.db.QueryContext(ctx, `
		SELECT author_did AS repo_did
		FROM appview_publication_scopes
		WHERE author_did <> ''
		UNION
		SELECT viewer_did AS repo_did
		FROM appview_viewer_feeds
		WHERE viewer_did <> ''
		UNION
		SELECT viewer_did AS repo_did
		FROM appview_publication_scopes
		WHERE viewer_did <> ''`)
	if err != nil {
		return nil, fmt.Errorf("query tracked DIDs: %w", err)
	}
	defer rows.Close()
	result := make(map[string]struct{})
	for rows.Next() {
		var did string
		if err := rows.Scan(&did); err != nil {
			return nil, fmt.Errorf("scan tracked DID: %w", err)
		}
		result[did] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate tracked DIDs: %w", err)
	}
	return result, nil
}

type Lease struct {
	Name         string
	OwnerID      string
	FencingToken int64
	ExpiresAt    time.Time
}

func (p *Postgres) AcquireLease(ctx context.Context, name, ownerID string, ttl time.Duration) (Lease, error) {
	row := p.db.QueryRowContext(ctx, `
		INSERT INTO appview_ingestion_leases
		  (environment, lease_name, source_generation, owner_id, fencing_token,
		   acquired_at, lease_expires_at, updated_at)
		VALUES ($1, $2, $3, $4, 1, NOW(), NOW() + $5::interval, NOW())
		ON CONFLICT (environment, lease_name) DO UPDATE SET
		  source_generation = EXCLUDED.source_generation,
		  owner_id = EXCLUDED.owner_id,
		  fencing_token = appview_ingestion_leases.fencing_token + 1,
		  acquired_at = NOW(), lease_expires_at = EXCLUDED.lease_expires_at,
		  released_at = NULL, updated_at = NOW()
		WHERE appview_ingestion_leases.released_at IS NOT NULL
		   OR appview_ingestion_leases.lease_expires_at <= NOW()
		   OR appview_ingestion_leases.owner_id = EXCLUDED.owner_id
		RETURNING fencing_token, lease_expires_at`,
		p.source.Environment, name, p.source.Generation, ownerID, postgresInterval(ttl))
	var lease Lease
	lease.Name = name
	lease.OwnerID = ownerID
	if err := row.Scan(&lease.FencingToken, &lease.ExpiresAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Lease{}, ErrLeaseUnavailable
		}
		return Lease{}, fmt.Errorf("acquire ingestion lease: %w", err)
	}
	return lease, nil
}

func (p *Postgres) RenewLease(ctx context.Context, lease Lease, ttl time.Duration) (Lease, error) {
	row := p.db.QueryRowContext(ctx, `
		UPDATE appview_ingestion_leases
		SET lease_expires_at = NOW() + $6::interval, updated_at = NOW()
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL
		  AND lease_expires_at > NOW()
		RETURNING lease_expires_at`, p.source.Environment, lease.Name, p.source.Generation,
		lease.OwnerID, lease.FencingToken, postgresInterval(ttl))
	if err := row.Scan(&lease.ExpiresAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Lease{}, ErrLeaseUnavailable
		}
		return Lease{}, fmt.Errorf("renew ingestion lease: %w", err)
	}
	return lease, nil
}

func (p *Postgres) ReleaseLease(ctx context.Context, lease Lease) error {
	result, err := p.db.ExecContext(ctx, `
		UPDATE appview_ingestion_leases
		SET released_at = NOW(), lease_expires_at = NOW(), updated_at = NOW()
		WHERE environment = $1 AND lease_name = $2 AND source_generation = $3
		  AND owner_id = $4 AND fencing_token = $5 AND released_at IS NULL`,
		p.source.Environment, lease.Name, p.source.Generation, lease.OwnerID, lease.FencingToken)
	if err != nil {
		return fmt.Errorf("release ingestion lease: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect ingestion lease release: %w", err)
	}
	if rows != 1 {
		return ErrLeaseUnavailable
	}
	return nil
}

func postgresInterval(duration time.Duration) string {
	return fmt.Sprintf("%f seconds", duration.Seconds())
}
