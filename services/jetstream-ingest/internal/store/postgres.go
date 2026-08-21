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

type Postgres struct {
	db     *sql.DB
	source ingest.SourceIdentity
}

type ReplayProgress struct {
	State            string
	AfterSeq         uint64
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

func (p *Postgres) LoadCheckpoint(ctx context.Context) (*ingest.Checkpoint, error) {
	row := p.db.QueryRowContext(ctx, `
		SELECT source_host, stream_nsid, filter_fingerprint, cursor_kind,
		       last_staged_seq, replay_bytes_downloaded, replay_state,
		       replay_retry_count, replay_range_resume_count, COALESCE(replay_etag, ''),
		       last_staged_at, replay_last_progress_at
		FROM appview_jetstream_checkpoints
		WHERE environment = $1 AND source_generation = $2`,
		p.source.Environment, p.source.Generation)
	var checkpoint ingest.Checkpoint
	var seq int64
	var lastStagedAt sql.NullTime
	var replayLastProgressAt sql.NullTime
	if err := row.Scan(&checkpoint.Host, &checkpoint.StreamNSID, &checkpoint.FilterFingerprint,
		&checkpoint.CursorKind, &seq, &checkpoint.ReplayBytesDownloaded, &checkpoint.ReplayState,
		&checkpoint.ReplayRetryCount, &checkpoint.ReplayRangeResumeCount, &checkpoint.ReplayETag,
		&lastStagedAt, &replayLastProgressAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("load Jetstream checkpoint: %w", err)
	}
	if seq < 0 {
		return nil, fmt.Errorf("stored Jetstream cursor is negative: %d", seq)
	}
	checkpoint.LastStagedSeq = uint64(seq)
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

	for _, event := range events {
		if p.source.IsWire() {
			if err := p.stageWireInboxEvent(ctx, tx, event); err != nil {
				return err
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

	result, err := tx.ExecContext(ctx, `
		INSERT INTO appview_jetstream_checkpoints
		  (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
		   cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
		   replay_state, replay_after_seq, replay_sealed_seq, replay_bytes_downloaded,
		   replay_retry_count, replay_range_resume_count, replay_etag,
		   replay_last_progress_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), $9, $10, $11, $12, $13, $14, $15, $16, NOW())
		ON CONFLICT (environment, source_generation) DO UPDATE SET
		  last_staged_seq = GREATEST(appview_jetstream_checkpoints.last_staged_seq, EXCLUDED.last_staged_seq),
		  last_staged_event_at = CASE
		    WHEN EXCLUDED.last_staged_seq >= appview_jetstream_checkpoints.last_staged_seq
		    THEN EXCLUDED.last_staged_event_at ELSE appview_jetstream_checkpoints.last_staged_event_at END,
		  last_staged_at = CASE
		    WHEN EXCLUDED.last_staged_seq > appview_jetstream_checkpoints.last_staged_seq
		    THEN NOW() ELSE appview_jetstream_checkpoints.last_staged_at END,
		  replay_state = EXCLUDED.replay_state,
		  replay_after_seq = EXCLUDED.replay_after_seq,
		  replay_sealed_seq = EXCLUDED.replay_sealed_seq,
		  replay_bytes_downloaded = EXCLUDED.replay_bytes_downloaded,
		  replay_retry_count = EXCLUDED.replay_retry_count,
		  replay_range_resume_count = EXCLUDED.replay_range_resume_count,
		  replay_etag = EXCLUDED.replay_etag,
		  replay_last_progress_at = CASE
		    WHEN EXCLUDED.last_staged_seq > appview_jetstream_checkpoints.last_staged_seq
		    THEN EXCLUDED.replay_last_progress_at
		    ELSE appview_jetstream_checkpoints.replay_last_progress_at END,
		  updated_at = NOW()
		WHERE appview_jetstream_checkpoints.source_host = EXCLUDED.source_host
		  AND appview_jetstream_checkpoints.stream_nsid = EXCLUDED.stream_nsid
		  AND appview_jetstream_checkpoints.filter_fingerprint = EXCLUDED.filter_fingerprint
		  AND appview_jetstream_checkpoints.cursor_kind = EXCLUDED.cursor_kind`,
		p.source.Environment, p.source.Generation, p.source.Host, p.source.StreamNSID,
		p.source.FilterFingerprint, p.source.CursorKind, int64(checkpointSeq), checkpointEventTime,
		progress.State, int64(progress.AfterSeq), int64(progress.SealedSeq), progress.BytesDownloaded,
		progress.RetryCount, progress.RangeResumeCount, nullableString(progress.ETag), progress.LastProgressAt,
	)
	if err != nil {
		return fmt.Errorf("advance Jetstream checkpoint: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect checkpoint advance: %w", err)
	}
	if rows != 1 {
		return errors.New("checkpoint source identity mismatch")
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit stage batch: %w", err)
	}
	return nil
}

func (p *Postgres) stageWireInboxEvent(
	ctx context.Context,
	tx *sql.Tx,
	event ingest.InboxEvent,
) error {
	payload := wireJSONPayloadForPostgres(event.Payload)
	_, err := tx.ExecContext(ctx, `
		INSERT INTO wire_ingestion_inbox
		  (environment, source_generation, seq, source_host, cursor_kind,
		   event_kind, repo_did, collection, operation, repo_rev, record_key,
		   record_cid, payload, event_time, status, attempt_count,
		   next_attempt_at, staged_at, updated_at)
		SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
		       $13::jsonb, $14, 'pending', 0, NOW(), NOW(), NOW()
		ON CONFLICT (environment, source_generation, seq) DO NOTHING`,
		p.source.Environment, p.source.Generation, int64(event.Seq), p.source.Host,
		p.source.CursorKind, event.Kind, event.RepoDID, event.Collection, event.Operation,
		event.RepoRev, event.RecordKey, event.RecordCID, string(payload), event.Time,
	)
	if err != nil {
		return fmt.Errorf("insert Wire inbox event %d: %w", event.Seq, err)
	}
	return nil
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
