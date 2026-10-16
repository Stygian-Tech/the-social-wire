package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

var ErrSourceDiscontinuity = errors.New("Jetstream source cursor discontinuity requires operator review")
var ErrRecoveryExpired = errors.New("automatic archive recovery deadline expired")

// RecoveryJob checkpoints archive coverage independently while staging into the
// parent's canonical inbox generation, which existing projection workers consume.
type RecoveryJob struct {
	ID                           string
	AfterSeq, BeforeSeq          uint64
	LastStagedSeq                *uint64
	Status                       string
	ExpiresAt                    *time.Time
	RetryCount, RangeResumeCount int
	ETag                         string
}

type AutomaticRecoveryState struct {
	LastLiveSeq, GapAfterSeq *uint64
	IncidentBytes            int64
	Status                   string
}

func (p *Postgres) StartAutomaticRecovery(ctx context.Context, lease Lease, checkpoint *ingest.Checkpoint, bootstrap *uint64, expiry *time.Time) (*AutomaticRecoveryState, error) {
	var last, gap any
	var bytes int64
	if checkpoint != nil {
		last = nullableCursorPointer(checkpoint.LastStagedSeq)
		bytes = checkpoint.ReplayBytesDownloaded
		if checkpoint.ReplayState != "live" {
			gap = last
		}
	} else if bootstrap != nil {
		gap = int64(*bootstrap)
	}
	buckets, err := p.ReplayUsageBuckets(ctx)
	if err != nil {
		return nil, err
	}
	var dailyBytes int64
	for _, bucket := range buckets {
		dailyBytes += bucket.Bytes
	}
	bytes = max(bytes, dailyBytes)
	err = retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		result, err := tx.ExecContext(ctx, `INSERT INTO ingestion_recovery_controllers(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_live_seq,gap_after_seq,incident_bytes_downloaded,status,canary_expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,CASE WHEN $8::bigint IS NULL THEN 'healthy' ELSE 'gap_pending' END,$10) ON CONFLICT(environment,source_generation) DO UPDATE SET incident_bytes_downloaded=GREATEST(ingestion_recovery_controllers.incident_bytes_downloaded,EXCLUDED.incident_bytes_downloaded),last_live_seq=GREATEST(ingestion_recovery_controllers.last_live_seq,EXCLUDED.last_live_seq),gap_after_seq=LEAST(ingestion_recovery_controllers.gap_after_seq,EXCLUDED.gap_after_seq),canary_expires_at=LEAST(ingestion_recovery_controllers.canary_expires_at,EXCLUDED.canary_expires_at),status=CASE WHEN ingestion_recovery_controllers.status='blocked_discontinuity' THEN ingestion_recovery_controllers.status WHEN EXCLUDED.gap_after_seq IS NOT NULL THEN 'gap_pending' ELSE ingestion_recovery_controllers.status END,updated_at=NOW() WHERE ingestion_recovery_controllers.source_host=EXCLUDED.source_host AND ingestion_recovery_controllers.stream_nsid=EXCLUDED.stream_nsid AND ingestion_recovery_controllers.filter_fingerprint=EXCLUDED.filter_fingerprint AND ingestion_recovery_controllers.cursor_kind=EXCLUDED.cursor_kind`, p.source.Environment, p.source.Generation, p.source.Host, p.source.StreamNSID, p.source.FilterFingerprint, p.source.CursorKind, last, gap, bytes, expiry)
		if err != nil {
			return err
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n != 1 {
			return ErrSourceDiscontinuity
		}
		return tx.Commit()
	})
	if err != nil {
		return nil, err
	}
	p.liveIntake = true
	p.quarantineEnabled = true
	return p.AutomaticRecoveryState(ctx)
}

func nullableCursorPointer(value *uint64) any {
	if value == nil {
		return nil
	}
	return int64(*value)
}

func (p *Postgres) AutomaticRecoveryState(ctx context.Context) (*AutomaticRecoveryState, error) {
	var last, gap sql.NullInt64
	var state AutomaticRecoveryState
	if err := p.db.QueryRowContext(ctx, `SELECT last_live_seq,gap_after_seq,incident_bytes_downloaded,status FROM ingestion_recovery_controllers WHERE environment=$1 AND source_generation=$2`, p.source.Environment, p.source.Generation).Scan(&last, &gap, &state.IncidentBytes, &state.Status); err != nil {
		return nil, err
	}
	var err error
	if state.LastLiveSeq, err = cursorPointer(last, "automatic live cursor"); err != nil {
		return nil, err
	}
	if state.GapAfterSeq, err = cursorPointer(gap, "automatic gap cursor"); err != nil {
		return nil, err
	}
	return &state, nil
}

func (p *Postgres) verifyRecoveryFence(ctx context.Context, tx *sql.Tx, lease Lease) error {
	var valid bool
	err := tx.QueryRowContext(ctx, `SELECT TRUE FROM appview_ingestion_leases WHERE environment=$1 AND lease_name=$2 AND source_generation=$3 AND owner_id=$4 AND fencing_token=$5 AND released_at IS NULL AND lease_expires_at>NOW() FOR SHARE`, p.source.Environment, lease.Name, p.source.Generation, lease.OwnerID, lease.FencingToken).Scan(&valid)
	if errors.Is(err, sql.ErrNoRows) || err == nil && !valid {
		return ErrLeaseUnavailable
	}
	return err
}

// MarkLiveCursorTooOld records the missing range before opening a fresh tail.
// Repeated failures cannot move the gap's starting boundary forward.
func (p *Postgres) MarkLiveCursorTooOld(ctx context.Context, lease Lease, after uint64) error {
	return retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET gap_after_seq=LEAST(COALESCE(gap_after_seq,$3),$3),status='gap_pending',last_error='CursorTooOld',updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity'`, p.source.Environment, p.source.Generation, int64(after))
		if err != nil {
			return err
		}
		return tx.Commit()
	})
}

func (p *Postgres) BlockSourceDiscontinuity(ctx context.Context, lease Lease, reason string) error {
	return retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET status='blocked_discontinuity',last_error=$3,updated_at=NOW() WHERE environment=$1 AND source_generation=$2`, p.source.Environment, p.source.Generation, reason)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_jobs SET status='blocked_discontinuity',last_error=$3,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'complete'`, p.source.Environment, p.source.Generation, reason)
		if err != nil {
			return err
		}
		return tx.Commit()
	})
}

// Called inside the same fenced transaction as inbox/checkpoint staging. New
// live data cannot leap past history until its immutable recovery obligation exists.
func (p *Postgres) stageLiveSeam(ctx context.Context, tx *sql.Tx, lastSeq uint64) error {
	var last, gap sql.NullInt64
	var status string
	var expiry sql.NullTime
	if err := tx.QueryRowContext(ctx, `SELECT last_live_seq,gap_after_seq,status,canary_expires_at FROM ingestion_recovery_controllers WHERE environment=$1 AND source_generation=$2 FOR UPDATE`, p.source.Environment, p.source.Generation).Scan(&last, &gap, &status, &expiry); err != nil {
		return err
	}
	if status == "blocked_discontinuity" || last.Valid && uint64(last.Int64) > lastSeq {
		return ErrSourceDiscontinuity
	}
	if gap.Valid {
		if lastSeq <= uint64(gap.Int64) {
			return ErrSourceDiscontinuity
		}
		id, err := newIncidentID()
		if err != nil {
			return err
		}
		// Include the last durable boundary for idempotent overlap. An event filtered
		// out by the provider does not become an invented staging checkpoint.
		after := uint64(gap.Int64)
		if after > 0 {
			after--
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO ingestion_recovery_jobs(environment,source_generation,id,source_host,stream_nsid,filter_fingerprint,cursor_kind,after_seq,before_seq,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) ON CONFLICT(environment,source_generation,after_seq,before_seq) DO NOTHING`, p.source.Environment, p.source.Generation, id, p.source.Host, p.source.StreamNSID, p.source.FilterFingerprint, p.source.CursorKind, int64(after), int64(lastSeq), expiry)
		if err != nil {
			return fmt.Errorf("register automatic recovery seam: %w", err)
		}
	}
	_, err := tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET last_live_seq=$3,gap_after_seq=NULL,status=CASE WHEN gap_after_seq IS NOT NULL THEN 'gap_pending' ELSE status END,updated_at=NOW() WHERE environment=$1 AND source_generation=$2`, p.source.Environment, p.source.Generation, int64(lastSeq))
	return err
}

func (p *Postgres) ClaimRecoveryJob(ctx context.Context, lease Lease, incidentLimit int64) (*RecoveryJob, error) {
	var job *RecoveryJob
	err := retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_jobs SET status='expired',last_error='Recovery canary deadline expired',updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status NOT IN('complete','expired','blocked_discontinuity') AND (expires_at<=NOW() OR EXISTS(SELECT 1 FROM ingestion_recovery_controllers controller WHERE controller.environment=ingestion_recovery_jobs.environment AND controller.source_generation=ingestion_recovery_jobs.source_generation AND controller.canary_expires_at<=NOW()))`, p.source.Environment, p.source.Generation)
		if err != nil {
			return err
		}
		var id, status, etag string
		var after, before int64
		var last sql.NullInt64
		var expiry sql.NullTime
		var retries, resumes int
		err = tx.QueryRowContext(ctx, `SELECT job.id,job.after_seq,job.before_seq,job.last_staged_seq,job.status,LEAST(job.expires_at,controller.canary_expires_at),job.retry_count,job.range_resume_count,COALESCE(job.etag,'') FROM ingestion_recovery_jobs job JOIN ingestion_recovery_controllers controller USING(environment,source_generation) WHERE job.environment=$1 AND job.source_generation=$2 AND controller.status<>'blocked_discontinuity' AND (job.expires_at IS NULL OR job.expires_at>NOW()) AND (controller.canary_expires_at IS NULL OR controller.canary_expires_at>NOW()) AND controller.incident_bytes_downloaded<$3 AND (job.status IN('pending','paused_daily','paused_budget') OR job.status='replaying' AND (job.lease_owner IS DISTINCT FROM $4 OR job.fencing_token IS DISTINCT FROM $5)) ORDER BY job.created_at,job.after_seq FOR UPDATE OF job SKIP LOCKED LIMIT 1`, p.source.Environment, p.source.Generation, incidentLimit, lease.OwnerID, lease.FencingToken).Scan(&id, &after, &before, &last, &status, &expiry, &retries, &resumes, &etag)
		if errors.Is(err, sql.ErrNoRows) {
			job = nil
			return tx.Commit()
		}
		if err != nil {
			return err
		}
		j := RecoveryJob{ID: id, AfterSeq: uint64(after), BeforeSeq: uint64(before), Status: "replaying", RetryCount: retries, RangeResumeCount: resumes, ETag: etag}
		j.LastStagedSeq, err = cursorPointer(last, "recovery job cursor")
		if err != nil {
			return err
		}
		if expiry.Valid {
			j.ExpiresAt = &expiry.Time
		}
		if _, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_jobs SET status='replaying',lease_owner=$4,fencing_token=$5,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND id=$3`, p.source.Environment, p.source.Generation, id, lease.OwnerID, lease.FencingToken); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET status='recovering',updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity'`, p.source.Environment, p.source.Generation); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		job = &j
		return nil
	})
	return job, err
}

func (p *Postgres) ForRecoveryJob(job RecoveryJob) *Postgres {
	return &Postgres{db: p.db, source: p.source, wireCompactIngestEnabled: p.wireCompactIngestEnabled, wireInboxMaxRows: p.wireInboxMaxRows, wireDatabaseMaxBytes: p.wireDatabaseMaxBytes, quarantineEnabled: true, recoveryJob: &job}
}

func (p *Postgres) loadRecoveryCheckpoint(ctx context.Context) (*ingest.Checkpoint, error) {
	j := p.recoveryJob
	var last, sealed sql.NullInt64
	var retries, resumes int
	var status, etag string
	var progress sql.NullTime
	err := p.db.QueryRowContext(ctx, `SELECT last_staged_seq,sealed_seq,status,retry_count,range_resume_count,COALESCE(etag,''),last_progress_at FROM ingestion_recovery_jobs WHERE environment=$1 AND source_generation=$2 AND id=$3`, p.source.Environment, p.source.Generation, j.ID).Scan(&last, &sealed, &status, &retries, &resumes, &etag, &progress)
	if err != nil {
		return nil, err
	}
	cursor, err := cursorPointer(last, "recovery checkpoint")
	if err != nil {
		return nil, err
	}
	sealedSeq, err := cursorPointer(sealed, "recovery sealed cursor")
	if err != nil {
		return nil, err
	}
	return &ingest.Checkpoint{Host: p.source.Host, StreamNSID: p.source.StreamNSID, FilterFingerprint: p.source.FilterFingerprint, CursorKind: p.source.CursorKind, LastStagedSeq: cursor, ReplayState: status, ReplayAfterSeq: &j.AfterSeq, ReplayBeforeSeq: &j.BeforeSeq, ReplaySealedSeq: sealedSeq, ReplayRetryCount: retries, ReplayRangeResumeCount: resumes, ReplayETag: etag, ReplayLastProgressAt: progress.Time}, nil
}

func (p *Postgres) stageRecoveryCheckpoint(ctx context.Context, tx *sql.Tx, lease Lease, last uint64, progress ReplayProgress, complete bool) error {
	j := p.recoveryJob
	status := "replaying"
	if complete {
		status = "complete"
	}
	result, err := tx.ExecContext(ctx, `UPDATE ingestion_recovery_jobs SET last_staged_seq=CASE WHEN $6::bigint IS NULL THEN last_staged_seq ELSE GREATEST(last_staged_seq,$6) END,sealed_seq=GREATEST(sealed_seq,$7),status=$8,retry_count=GREATEST(retry_count,$9),range_resume_count=GREATEST(range_resume_count,$10),etag=$11,last_progress_at=CASE WHEN $8='complete' OR last_staged_seq IS NULL OR $6::bigint>last_staged_seq THEN NOW() ELSE last_progress_at END,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND id=$3 AND lease_owner=$4 AND fencing_token=$5 AND status='replaying' AND (expires_at IS NULL OR expires_at>NOW()) AND after_seq=$12 AND before_seq=$13 AND NOT EXISTS(SELECT 1 FROM ingestion_recovery_controllers controller WHERE controller.environment=$1 AND controller.source_generation=$2 AND (controller.status='blocked_discontinuity' OR controller.canary_expires_at<=NOW()))`, p.source.Environment, p.source.Generation, j.ID, lease.OwnerID, lease.FencingToken, nullableCursor(last), int64(progress.SealedSeq), status, progress.RetryCount, progress.RangeResumeCount, nullableString(progress.ETag), int64(j.AfterSeq), int64(j.BeforeSeq))
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return errors.New("recovery job ownership, range, deadline or source identity changed")
	}
	if complete {
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers controller SET status=CASE WHEN EXISTS(SELECT 1 FROM ingestion_poison_records poison WHERE poison.environment=controller.environment AND poison.source_generation=controller.source_generation AND poison.status<>'repaired') THEN 'degraded' WHEN EXISTS(SELECT 1 FROM ingestion_recovery_jobs job WHERE job.environment=controller.environment AND job.source_generation=controller.source_generation AND job.status<>'complete') THEN controller.status ELSE 'healthy' END,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity'`, p.source.Environment, p.source.Generation)
	}
	return err
}

func (p *Postgres) CompleteRecoveryJob(ctx context.Context, lease Lease, after, before uint64, progress ReplayProgress) error {
	if p.recoveryJob == nil || p.recoveryJob.AfterSeq != after || p.recoveryJob.BeforeSeq != before || progress.SealedSeq != before {
		return errors.New("recovery completion lacks exact sealed range")
	}
	return retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		if err := p.stageRecoveryCheckpoint(ctx, tx, lease, 0, progress, true); err != nil {
			return err
		}
		return tx.Commit()
	})
}

func (p *Postgres) ReleaseRecoveryJob(ctx context.Context, lease Lease, job RecoveryJob, status, reason string, evidence ReplayProgress) error {
	switch status {
	case "pending", "paused_daily", "paused_budget", "expired", "blocked_discontinuity":
	default:
		return errors.New("invalid recovery release state")
	}
	return retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_jobs SET status=$6,last_error=$7,retry_count=GREATEST(retry_count,$8),range_resume_count=GREATEST(range_resume_count,$9),etag=COALESCE($10,etag),updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND id=$3 AND lease_owner=$4 AND fencing_token=$5 AND status='replaying'`, p.source.Environment, p.source.Generation, job.ID, lease.OwnerID, lease.FencingToken, status, reason, evidence.RetryCount, evidence.RangeResumeCount, nullableString(evidence.ETag))
		if err != nil {
			return err
		}
		if status == "paused_budget" || status == "expired" {
			_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET status=$3,last_error=$4,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity'`, p.source.Environment, p.source.Generation, status, reason)
			if err != nil {
				return err
			}
		}
		return tx.Commit()
	})
}

// The canonical parent generation owns both rolling usage and the incident byte
// total. Jobs and restarts can never obtain a fresh archive allowance.
func (p *Postgres) recordAutomaticReplayBytes(ctx context.Context, bytes int64) error {
	return retryStageSerialization(ctx, func() error {
		tx, err := p.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		_, err = tx.ExecContext(ctx, `INSERT INTO appview_ingestion_replay_usage(environment,source_generation,bucket_started_at,bytes_downloaded,updated_at) VALUES($1,$2,date_trunc('minute',NOW()),$3,NOW()) ON CONFLICT(environment,source_generation,bucket_started_at) DO UPDATE SET bytes_downloaded=appview_ingestion_replay_usage.bytes_downloaded+EXCLUDED.bytes_downloaded,updated_at=NOW()`, p.source.Environment, p.source.Generation, bytes)
		if err != nil {
			return err
		}
		result, err := tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET incident_bytes_downloaded=incident_bytes_downloaded+$3,updated_at=NOW() WHERE environment=$1 AND source_generation=$2`, p.source.Environment, p.source.Generation, bytes)
		if err != nil {
			return err
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n != 1 {
			return errors.New("automatic replay budget authority missing")
		}
		return tx.Commit()
	})
}

func (p *Postgres) PauseAutomaticRecovery(ctx context.Context, lease Lease, reason string) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := p.verifyRecoveryFence(ctx, tx, lease); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers controller SET status='paused_budget',last_error=$3,updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity' AND EXISTS(SELECT 1 FROM ingestion_recovery_jobs job WHERE job.environment=controller.environment AND job.source_generation=controller.source_generation AND job.status NOT IN('complete','expired','blocked_discontinuity'))`, p.source.Environment, p.source.Generation, reason)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (p *Postgres) EnablePoisonProtection(ctx context.Context, lease Lease, checkpoint *ingest.Checkpoint) error {
	var baseline *ingest.Checkpoint
	if checkpoint != nil {
		copy := *checkpoint
		copy.ReplayState = "live"
		baseline = &copy
	}
	if _, err := p.StartAutomaticRecovery(ctx, lease, baseline, nil, nil); err != nil {
		return err
	}
	p.liveIntake = false
	return nil
}
