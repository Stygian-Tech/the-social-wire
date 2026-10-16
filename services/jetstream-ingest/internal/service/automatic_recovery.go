package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

var errLiveCursorRequiresArchive = errors.New("live cursor requires bounded same-host archive recovery")

// The pinned SDK does not export its terminal WebSocket-frame error type.
// Accept only its exact diagnostic prefix and code, walking wrapping errors.
func pinnedLiveFrameCode(err error) string {
	for err != nil {
		for _, code := range []string{"FutureCursor", "CursorTooOld"} {
			prefix := "jetstream: live stream error: " + code
			if err.Error() == prefix || strings.HasPrefix(err.Error(), prefix+": ") {
				return code
			}
		}
		err = errors.Unwrap(err)
	}
	return ""
}

// One fenced parent owns a pure live tail and a single independently checkpointed
// archive worker. Neither archive budget exhaustion nor expiry stops fresh intake.
func (r *Runner) runAutomatic(ctx context.Context) error {
	if r.initializationError != nil {
		return r.initializationError
	}
	if !r.cfg.SupportsAutomaticRecovery() {
		return errors.New("automatic recovery scope lacks ordered projection fences")
	}
	checkpoint, err := r.store.LoadCheckpoint(ctx)
	if err != nil {
		return err
	}
	if err := requireBootstrapSeam(checkpoint, r.cfg.BootstrapAfterSeq); err != nil {
		return err
	}
	state, err := r.store.StartAutomaticRecovery(ctx, r.lease, checkpoint, r.cfg.BootstrapAfterSeq, r.cfg.ReplayCanaryExpiresAt)
	if err != nil {
		return err
	}
	buckets, err := r.store.ReplayUsageBuckets(ctx)
	if err != nil {
		return err
	}
	r.budget.Seed(state.IncidentBytes, buckets)
	if err := r.store.PruneReplayUsage(ctx); err != nil {
		return err
	}
	r.liveOnly = true
	r.sharedRecoveryBudget = true
	r.providerRejections = &ingest.ProviderRejections{}
	if state.LastLiveSeq != nil {
		r.lastSeq.Store(*state.LastLiveSeq)
	}
	recoveryContext, stopRecovery := context.WithCancel(ctx)
	recoveryDone := make(chan struct{})
	go func() { defer close(recoveryDone); r.runRecoveryJobs(recoveryContext) }()
	defer func() { stopRecovery(); <-recoveryDone }()
	delay := r.cfg.BackoffMin
	for ctx.Err() == nil {
		state, err = r.store.AutomaticRecoveryState(ctx)
		if err != nil {
			return err
		}
		if state.Status == "blocked_discontinuity" {
			stopRecovery()
			r.health.Stream(false)
			r.health.Paused(true)
			r.health.Error(store.ErrSourceDiscontinuity)
			<-ctx.Done()
			return nil
		}
		r.liveCursor = 0
		if state.GapAfterSeq == nil && state.LastLiveSeq != nil {
			r.liveCursor = *state.LastLiveSeq
		}
		r.providerRejections.Clear()
		before := r.lastSeq.Load()
		err = r.runOnce(ctx)
		if ctx.Err() != nil {
			return nil
		}
		r.health.Stream(false)
		r.health.Error(err)
		rejection := r.providerRejections.Snapshot()
		if rejection.Code == "CursorTooOld" || errors.Is(err, errLiveCursorRequiresArchive) {
			if err := r.store.MarkLiveCursorTooOld(ctx, r.lease, r.lastSeq.Load()); err != nil {
				return err
			}
			r.logger.Warn("live cursor left provider buffer; registering bounded recovery independently of live intake", "lastSeq", r.lastSeq.Load())
			continue
		}
		if errors.Is(err, store.ErrSourceDiscontinuity) || rejection.Code == "FutureCursor" || rejection.Code == "InvalidRequest" && strings.Contains(strings.ToLower(rejection.Message), "cursor") {
			reason := fmt.Sprintf("%v; provider=%s %s", err, rejection.Code, rejection.Message)
			if blockErr := r.store.BlockSourceDiscontinuity(ctx, r.lease, reason); blockErr != nil {
				return blockErr
			}
			stopRecovery()
			continue
		}
		r.recordIncident(ctx, err)
		if r.lastSeq.Load() > before {
			delay = r.cfg.BackoffMin
		}
		r.logger.Warn("live-only subscription stopped; resuming durable live cursor", "delay", delay, "error", err)
		if !sleepContext(ctx, jitterDuration(delay)) {
			return nil
		}
		delay = min(delay*2, r.cfg.BackoffMax)
	}
	return nil
}

func (r *Runner) runRecoveryJobs(ctx context.Context) {
	nextPrune := time.Time{}
	for ctx.Err() == nil {
		if !time.Now().Before(nextPrune) {
			if err := r.store.PrunePoisonPayloads(ctx); err != nil {
				r.logger.Warn("prune bounded poison evidence", "error", err)
			}
			nextPrune = time.Now().Add(time.Minute)
		}
		if err := r.budget.CheckIncidentCapacity(); err != nil {
			if pauseErr := r.store.PauseAutomaticRecovery(ctx, r.lease, err.Error()); pauseErr != nil {
				r.logger.Error("persist automatic recovery budget pause", "error", pauseErr)
			}
			if !sleepContext(ctx, 30*time.Second) {
				return
			}
			continue
		}
		if wait := r.budget.WaitForDailyCapacity(); wait > 0 {
			if !sleepContext(ctx, min(wait, 30*time.Second)) {
				return
			}
			continue
		}
		job, err := r.store.ClaimRecoveryJob(ctx, r.lease, r.cfg.ReplayIncidentBytes)
		if err != nil {
			r.logger.Error("claim bounded recovery job", "error", err)
			if !sleepContext(ctx, time.Second) {
				return
			}
			continue
		}
		if job == nil {
			if !sleepContext(ctx, time.Second) {
				return
			}
			continue
		}
		cfg := r.cfg
		cfg.AutomaticRecoveryEnabled = false
		cfg.ReplaySnapshotOnly = true
		cfg.BootstrapAfterSeq = &job.AfterSeq
		cfg.ReplayBeforeSeq = &job.BeforeSeq
		child := NewRunner(cfg, r.store.ForRecoveryJob(*job), r.lease, &health.State{}, r.logger.With("recoveryJob", job.ID))
		// Pacing and byte accounting are shared rather than replenished per child.
		child.admissionLimiter = r.admissionLimiter
		child.budget = r.budget
		child.sharedRecoveryBudget = true
		child.evidence.Seed(job.RetryCount, job.RangeResumeCount, job.ETag)
		if job.LastStagedSeq != nil {
			child.lastSeq.Store(*job.LastStagedSeq)
		}
		jobContext, cancel := context.WithCancel(ctx)
		if job.ExpiresAt != nil {
			cancel()
			jobContext, cancel = context.WithDeadlineCause(ctx, *job.ExpiresAt, store.ErrRecoveryExpired)
		}
		err = child.runOnce(jobContext)
		cause := context.Cause(jobContext)
		cancel()
		if errors.Is(err, errSnapshotComplete) {
			continue
		}
		if ctx.Err() != nil {
			return
		}
		status := "pending"
		switch {
		case errors.Is(cause, store.ErrRecoveryExpired):
			status = "expired"
		case errors.Is(err, ingest.ErrIncidentBudgetExceeded):
			status = "paused_budget"
		case errors.Is(err, ingest.ErrDailyBudgetExceeded):
			status = "paused_daily"
		case errors.Is(err, store.ErrSourceDiscontinuity):
			status = "blocked_discontinuity"
			if blockErr := r.store.BlockSourceDiscontinuity(ctx, r.lease, err.Error()); blockErr != nil {
				r.logger.Error("persist recovery source discontinuity", "error", blockErr)
			}
		}
		reason := fmt.Sprint(err)
		if cause != nil {
			reason = cause.Error()
		}
		evidence := child.evidence.Snapshot()
		if releaseErr := r.store.ReleaseRecoveryJob(ctx, r.lease, *job, status, reason, store.ReplayProgress{RetryCount: evidence.RetryCount, RangeResumeCount: evidence.RangeResumeCount, ETag: evidence.ETag}); releaseErr != nil {
			r.logger.Error("retain bounded recovery failure", "job", job.ID, "error", releaseErr)
		}
		r.logger.Warn("historical recovery stopped; live intake remains independent", "job", job.ID, "state", status, "error", reason)
		if !sleepContext(ctx, r.cfg.BackoffMin) {
			return
		}
	}
}

func (r *Runner) prunePoisonEvidence(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		if err := r.store.PrunePoisonPayloads(ctx); err != nil && ctx.Err() == nil {
			r.logger.Warn("prune bounded poison evidence", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
