package service

import (
	"context"
	"errors"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
)

var ErrReplayCanaryExpired = errors.New("Wire replay canary deadline expired; operator review required")

// RunWithReplayCanary gives a Wire lane an absolute, restart-stable operating
// window. Every eligible owner must retain the same configured UTC expiry.
// The callback must join its workers before returning; expiry never detaches
// work, resets durable evidence, or cancels a sibling lane.
func RunWithReplayCanary(
	ctx context.Context, cfg config.Config, state *health.State,
	run func(context.Context) error,
) error {
	if cfg.PipelineMode != config.WirePipelineMode || cfg.ReplayCanaryExpiresAt == nil {
		return run(ctx)
	}
	laneContext, cancel := context.WithDeadlineCause(ctx, *cfg.ReplayCanaryExpiresAt, ErrReplayCanaryExpired)
	defer cancel()
	var err error
	// An expired restart must not open the database, acquire ownership, reconcile
	// admission, or issue an archive request before observing its retained expiry.
	if laneContext.Err() == nil {
		err = run(laneContext)
	}
	if ctx.Err() != nil {
		return err
	}
	if errors.Is(context.Cause(laneContext), ErrReplayCanaryExpired) || !time.Now().Before(*cfg.ReplayCanaryExpiresAt) {
		state.Lease(false)
		state.Stream(false)
		state.Paused(true)
		state.Error(ErrReplayCanaryExpired)
		// Returning would trigger supervisor retries (or exit the standalone process).
		// Park only this lane, retaining the reason in health until operator action.
		<-ctx.Done()
		return nil
	}
	return err
}
