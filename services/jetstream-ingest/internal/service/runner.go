package service

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

type Runner struct {
	cfg        config.Config
	store      *store.Postgres
	health     *health.State
	logger     *slog.Logger
	budget     *ingest.ReplayBudget
	registry   *DIDRegistry
	lease      store.Lease
	evidence   *ingest.TransportEvidence
	lastSeq    atomic.Uint64
	lastSealed atomic.Uint64
}

func NewRunner(cfg config.Config, database *store.Postgres, lease store.Lease, state *health.State, logger *slog.Logger) *Runner {
	return &Runner{
		cfg: cfg, store: database, health: state, logger: logger,
		budget:   ingest.NewReplayBudget(cfg.ReplayIncidentBytes, cfg.ReplayDailyBytes),
		registry: &DIDRegistry{store: database},
		lease:    lease,
		evidence: ingest.NewTransportEvidence(),
	}
}

func (r *Runner) Run(ctx context.Context) error {
	buckets, err := r.store.ReplayUsageBuckets(ctx)
	if err != nil {
		return err
	}
	checkpoint, err := r.store.LoadCheckpoint(ctx)
	if err != nil {
		return err
	}
	var incidentBytes int64
	progressSeed := time.Now().UTC()
	if checkpoint != nil {
		incidentBytes = checkpoint.ReplayBytesDownloaded
		r.lastSeq.Store(checkpoint.LastStagedSeq)
		progressSeed = latestProgressTime(checkpoint.LastStagedAt, checkpoint.ReplayLastProgressAt, progressSeed)
		if checkpoint.ReplayState == "replaying" {
			r.evidence.Seed(checkpoint.ReplayRetryCount, checkpoint.ReplayRangeResumeCount, checkpoint.ReplayETag)
		}
	}
	r.budget.Seed(incidentBytes, buckets)
	if err := r.store.PruneReplayUsage(ctx); err != nil {
		return err
	}
	if err := r.registry.Load(ctx); err != nil {
		return err
	}
	go r.registry.Run(ctx, r.cfg.TrackedDIDRefresh, r.logger)
	go r.monitorNoProgress(ctx, progressSeed)
	delay := r.cfg.BackoffMin
	for ctx.Err() == nil {
		beforeSeq := r.lastSeq.Load()
		err := r.runOnce(ctx)
		if r.lastSeq.Load() > beforeSeq {
			delay = r.cfg.BackoffMin
		}
		if ctx.Err() != nil {
			return nil
		}
		r.health.Stream(false)
		r.health.Error(err)
		r.recordIncident(ctx, err)
		if errors.Is(err, ingest.ErrDailyBudgetExceeded) {
			wait := r.budget.WaitForDailyCapacity()
			if wait == 0 {
				wait = r.cfg.ReplayBudgetPause
			}
			r.health.Paused(true)
			r.health.Stream(true)
			r.updateReplayState(ctx, "paused_budget")
			r.logger.Error("Jetstream replay daily budget exhausted", "wait", wait, "error", err)
			if !sleepContext(ctx, wait) {
				return nil
			}
			r.health.Paused(false)
			continue
		}
		if errors.Is(err, ingest.ErrIncidentBudgetExceeded) {
			r.health.Paused(true)
			r.health.Stream(true)
			r.updateReplayState(ctx, "paused_budget")
			r.logger.Error(
				"Jetstream replay incident budget exhausted; operator intervention or a higher configured limit is required",
				"error", err,
			)
			// The per-incident limit is a hard safety boundary. Resetting it on a
			// timer would let one recovery consume the limit repeatedly while still
			// referring to the same sealed/live seam. A restart retains the durable
			// byte count, while a configuration change can deliberately raise the
			// limit for this recovery.
			<-ctx.Done()
			return nil
		}
		jitter := jitterDuration(delay)
		r.logger.Warn("Jetstream subscription stopped; retrying from durable cursor", "delay", jitter, "error", err)
		if !sleepContext(ctx, jitter) {
			return nil
		}
		delay *= 2
		if delay > r.cfg.BackoffMax {
			delay = r.cfg.BackoffMax
		}
	}
	return nil
}

func latestProgressTime(lastStagedAt, replayLastProgressAt, fallback time.Time) time.Time {
	latest := lastStagedAt
	if replayLastProgressAt.After(latest) {
		latest = replayLastProgressAt
	}
	if latest.IsZero() {
		return fallback
	}
	return latest
}

func (r *Runner) updateReplayState(ctx context.Context, state string) {
	evidence := r.evidence.Snapshot()
	progress := store.ReplayProgress{
		State: state, BytesDownloaded: r.budget.IncidentUsed(), RetryCount: evidence.RetryCount,
		RangeResumeCount: evidence.RangeResumeCount, ETag: evidence.ETag,
	}
	if err := r.store.UpdateReplayState(ctx, r.lease, progress); err != nil {
		r.logger.Error("could not update replay state", "state", state, "error", err)
	}
}

func (r *Runner) runOnce(ctx context.Context) error {
	checkpoint, err := r.store.LoadCheckpoint(ctx)
	if err != nil {
		return err
	}

	options := []jetstream.Option{
		jetstream.WithCollections(r.cfg.Collections),
		jetstream.WithBatchSize(r.cfg.BatchSize),
		jetstream.WithDownloadConcurrency(r.cfg.DownloadConcurrency),
		jetstream.WithSegmentStripes(r.cfg.SegmentStripes),
		jetstream.WithMaxDownloadAttempts(r.cfg.MaxDownloadAttempts),
		jetstream.WithAPIKey(r.cfg.APIKey),
		jetstream.WithLogger(r.logger),
		jetstream.WithHTTPClient(&http.Client{Transport: ingest.BudgetTransport{
			Base: http.DefaultTransport, Budget: r.budget, RecordUsage: r.store.RecordReplayBytes,
			Evidence: r.evidence,
		}}),
	}
	var replayAfter uint64
	replaying := false
	if checkpoint != nil {
		replayAfter = inclusiveReplayAfter(checkpoint.LastStagedSeq)
		options = append(options, jetstream.WithAfterSeq(replayAfter))
		replaying = true
	} else if r.cfg.BootstrapAfterSeq != nil {
		replayAfter = *r.cfg.BootstrapAfterSeq
		options = append(options, jetstream.WithAfterSeq(replayAfter))
		replaying = true
	}

	client, err := jetstream.Subscribe(r.cfg.Host, options...)
	if err != nil {
		return fmt.Errorf("create Jetstream V2 subscription: %w", err)
	}
	defer client.Close()
	r.health.Stream(true)

	for batch, streamErr := range client.Events(ctx) {
		if streamErr != nil {
			// Never allow a later batch to checkpoint past an undecoded or failed
			// archive unit. A new client resumes from the last committed DB cursor.
			return fmt.Errorf("Jetstream V2 stream: %w", streamErr)
		}
		if batch == nil || len(batch.Events()) == 0 {
			continue
		}
		tracked := r.registry.Snapshot()
		prepared, lastSeq, lastEventTime, err := ingest.PrepareBatch(batch.Events(), tracked)
		if err != nil {
			return err
		}
		if lastSeq != batch.LastCursor() {
			return fmt.Errorf("batch cursor mismatch: prepared %d SDK %d", lastSeq, batch.LastCursor())
		}
		stats := client.Stats()
		r.lastSealed.Store(stats.SealedTip)
		state := "live"
		if replaying && (stats.SealedTip == 0 || stats.ResidualGap > 0) {
			state = "replaying"
		}
		if state == "live" {
			replaying = false
			r.budget.ResetIncident()
		}
		evidence := r.evidence.Snapshot()
		progress := store.ReplayProgress{
			State: state, AfterSeq: replayAfter, SealedSeq: stats.SealedTip,
			BytesDownloaded: r.budget.IncidentUsed(), RetryCount: evidence.RetryCount,
			RangeResumeCount: evidence.RangeResumeCount, ETag: evidence.ETag,
			LastProgressAt: time.Now().UTC(),
		}
		if err := r.store.StageBatch(ctx, r.lease, prepared, lastSeq, lastEventTime, progress); err != nil {
			return err
		}
		previousSeq := r.lastSeq.Load()
		r.lastSeq.Store(lastSeq)
		if lastSeq > previousSeq {
			r.health.Progress(lastSeq)
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	return errors.New("Jetstream V2 event iterator ended unexpectedly")
}

func (r *Runner) recordIncident(ctx context.Context, err error) {
	if err == nil {
		return
	}
	evidence := r.evidence.Snapshot()
	category := classifyIncident(err)
	lastSeq := r.lastSeq.Load()
	signal := store.IncidentSignal{
		Category: category, StartCursor: lastSeq, EndCursor: lastSeq, LastError: err.Error(),
		ReplayState: "recovering", BytesDownloaded: r.budget.IncidentUsed(),
		RetryCount: evidence.RetryCount, RangeResumeCount: evidence.RangeResumeCount,
		SealedSeq: r.lastSealed.Load(),
	}
	if incidentErr := r.store.UpsertIncident(ctx, signal); incidentErr != nil {
		r.logger.Error("could not persist consolidated ingestion incident", "category", category, "error", incidentErr)
	}
}

func classifyIncident(err error) string {
	if errors.Is(err, ingest.ErrDailyBudgetExceeded) || errors.Is(err, ingest.ErrIncidentBudgetExceeded) {
		return "replay_budget"
	}
	if errors.Is(err, jetstream.ErrFatal) {
		return "fatal_stream"
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "consumertooslow") || strings.Contains(message, "consumer too slow") {
		return "consumer_too_slow"
	}
	return "transport_error"
}

func (r *Runner) monitorNoProgress(ctx context.Context, startedAt time.Time) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			lastProgress := r.health.LastProgress()
			if lastProgress.IsZero() {
				lastProgress = startedAt
			}
			if now.Sub(lastProgress) < 24*time.Hour {
				continue
			}
			evidence := r.evidence.Snapshot()
			lastSeq := r.lastSeq.Load()
			signal := store.IncidentSignal{
				Category: "no_progress_24h", StartCursor: lastSeq, EndCursor: lastSeq,
				LastError:   "no Jetstream V2 staging progress for at least 24 hours",
				ReplayState: "failed", BytesDownloaded: r.budget.IncidentUsed(),
				RetryCount: evidence.RetryCount, RangeResumeCount: evidence.RangeResumeCount,
				SealedSeq: r.lastSealed.Load(),
			}
			if err := r.store.UpsertIncident(ctx, signal); err != nil {
				r.logger.Error("could not persist no-progress incident", "error", err)
			}
		}
	}
}

func inclusiveReplayAfter(lastStaged uint64) uint64 {
	if lastStaged == 0 {
		return 0
	}
	return lastStaged - 1
}

type DIDRegistry struct {
	mu    sync.RWMutex
	store *store.Postgres
	dids  map[string]struct{}
}

func (r *DIDRegistry) Run(ctx context.Context, interval time.Duration, logger *slog.Logger) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := r.Load(ctx); err != nil {
				logger.Warn("could not refresh tracked DID lifecycle filter", "error", err)
			}
		}
	}
}

func (r *DIDRegistry) Load(ctx context.Context) error {
	dids, err := r.store.TrackedDIDs(ctx)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.dids = dids
	r.mu.Unlock()
	return nil
}

func (r *DIDRegistry) Snapshot() map[string]struct{} {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make(map[string]struct{}, len(r.dids))
	for did := range r.dids {
		result[did] = struct{}{}
	}
	return result
}

func jitterDuration(maximum time.Duration) time.Duration {
	if maximum <= 1 {
		return maximum
	}
	value, err := rand.Int(rand.Reader, big.NewInt(int64(maximum)))
	if err != nil {
		return maximum
	}
	// Full jitter with a small floor prevents a hot zero-delay reconnect loop.
	return maximum/4 + time.Duration(value.Int64()*3/4)
}

func sleepContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
