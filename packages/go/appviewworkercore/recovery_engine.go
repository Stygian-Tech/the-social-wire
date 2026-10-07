package appviewworkercore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"log/slog"
	"sync"
	"time"
)

type RecoveryEngine struct {
	Store                              BackfillStore
	PDS                                *thinappviewcore.PDSClient
	Projector                          *EventProjectorRuntime
	RelayURL                           string
	MaximumAuthors, RecordCapPerAuthor int
	Replay                             RecoveryReplayTransport
	HeartbeatInterval                  time.Duration
}

func recoveryWait(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (e *RecoveryEngine) Run(ctx context.Context) error {
	if e.PDS == nil || e.Projector == nil || e.Projector.DB == nil || e.Store.DB == nil || e.RelayURL == "" || e.Store.WorkerID == "" || e.Store.Environment == "" {
		return errors.New("Operations recovery executor configuration unavailable")
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		job, err := e.Store.Claim(ctx, time.Now().UTC())
		if err == nil && job != nil {
			err = e.Execute(ctx, *job)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			slog.Error("Operations recovery job failed; diagnostic work retained")
		}
		if job == nil || err != nil {
			if err = recoveryWait(ctx, 5*time.Second); err != nil {
				return err
			}
		}
	}
}

// ownedRecoveryLease serializes version increments from heartbeats, progress and
// operator-visible reports. Losing a mutation cancels transport and joins work.
type ownedRecoveryLease struct {
	engine  *RecoveryEngine
	mu      sync.Mutex
	job     BackfillJob
	cancel  context.CancelFunc
	stopped bool
}

func (l *ownedRecoveryLease) mutate(ctx context.Context, operation func(BackfillJob) (BackfillJob, error)) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopped {
		return ErrBackfillLease
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	next, err := operation(l.job)
	if err != nil {
		l.stopped = true
		l.cancel()
		return err
	}
	l.job = next
	return nil
}
func (l *ownedRecoveryLease) checkpoint(ctx context.Context, p recoveryProgress) error {
	return l.mutate(ctx, func(job BackfillJob) (BackfillJob, error) {
		job.Processed = max(job.Processed, p.Processed)
		job.Failed = max(job.Failed, p.Failed)
		job.Reconciled = max(job.Reconciled, p.Reconciled)
		job.CheckpointCursor = p.Cursor
		return l.engine.Store.Checkpoint(ctx, job, time.Now().UTC())
	})
}
func (l *ownedRecoveryLease) heartbeat(ctx context.Context) {
	interval := l.engine.HeartbeatInterval
	if interval <= 0 {
		interval = 5 * time.Second
	}
	for {
		if recoveryWait(ctx, interval) != nil {
			return
		}
		if err := l.mutate(ctx, func(job BackfillJob) (BackfillJob, error) {
			return l.engine.Store.Checkpoint(ctx, job, time.Now().UTC())
		}); err != nil {
			return
		}
	}
}
func (l *ownedRecoveryLease) snapshot() BackfillJob { l.mu.Lock(); defer l.mu.Unlock(); return l.job }

type recoveryProgress struct {
	Cursor                        *int64
	Processed, Failed, Reconciled int
}
type recoveryProgressState struct {
	mu    sync.Mutex
	value recoveryProgress
}

func (p *recoveryProgressState) snapshot() recoveryProgress {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.value
}
func (p *recoveryProgressState) record(cursor *int64, failure bool) recoveryProgress {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.value.Processed++
	if failure {
		p.value.Failed++
	} else {
		p.value.Reconciled++
		if cursor != nil {
			v := *cursor
			p.value.Cursor = &v
		}
	}
	return p.value
}
func (p *recoveryProgressState) failures(count int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.value.Processed += count
	p.value.Failed += count
}
func (e *RecoveryEngine) Execute(ctx context.Context, job BackfillJob) error {
	if e.PDS == nil || e.Projector == nil || e.Projector.DB == nil || e.Store.DB == nil {
		return errors.New("Operations recovery executor configuration unavailable")
	}
	workCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	lease := &ownedRecoveryLease{engine: e, job: job, cancel: cancel}
	heartbeatDone := make(chan struct{})
	go func() { defer close(heartbeatDone); lease.heartbeat(workCtx) }()
	defer func() { cancel(); <-heartbeatDone }()
	progress := &recoveryProgressState{value: recoveryProgress{Cursor: job.CheckpointCursor, Processed: job.Processed, Failed: job.Failed, Reconciled: job.Reconciled}}
	truncated := false
	initialErr := lease.mutate(workCtx, func(current BackfillJob) (BackfillJob, error) {
		return e.Store.Checkpoint(workCtx, current, time.Now().UTC())
	})
	if initialErr != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if workCtx.Err() != nil {
			return nil
		}
		return initialErr
	}
	var err error
	switch job.SourceMode {
	case "pds_reconciliation":
		truncated, err = e.executePDS(workCtx, job, lease, progress)
	case "jetstream_replay":
		err = e.executeReplay(workCtx, job, lease, progress)
	case "tap_verified_resync":
		err = errors.New("tap_verified_resync_unavailable")
	default:
		err = errors.New("unsupported_recovery_source")
	}
	if err == nil {
		err = lease.checkpoint(workCtx, progress.snapshot())
	}
	if err == nil {
		err = lease.mutate(workCtx, func(current BackfillJob) (BackfillJob, error) {
			return e.Store.DiagnosticVerification(workCtx, current, truncated, time.Now().UTC())
		})
	}
	if err == nil {
		err = lease.mutate(workCtx, func(current BackfillJob) (BackfillJob, error) {
			return e.Store.Terminal(workCtx, current, "completed", nil, time.Now().UTC())
		})
	}
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(err, ErrBackfillLease) || workCtx.Err() != nil {
		return nil
	}
	reason := recoveryErrorCategory(err)
	_ = lease.mutate(workCtx, func(current BackfillJob) (BackfillJob, error) {
		return e.Store.Terminal(workCtx, current, "failed", &reason, time.Now().UTC())
	})
	return err
}
func recoveryIdentityHash(identity string) string {
	sum := sha256.Sum256([]byte(identity))
	return hex.EncodeToString(sum[:12])
}
func recoveryErrorCategory(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, ErrBackfillLease):
		return "concurrency_conflict"
	}
	switch err.Error() {
	case "tap_verified_resync_unavailable", "unsupported_recovery_source", "replay_requires_upper_bound", "replay_incomplete", "replay_stalled":
		return err.Error()
	}
	return "recovery_operation_failed"
}
