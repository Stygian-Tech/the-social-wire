package service

import (
	"context"
	"errors"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

func TestLiveProgressExpiresOnlyCaughtUpSubscription(t *testing.T) {
	now := time.Unix(1000, 0)
	live := jetstream.Stats{SealedTip: 100, PlannedThrough: 100}
	watch := liveProgressWatch{}
	if watch.stalled(now, 100, live, false) || watch.stalled(now.Add(liveProgressTimeout-time.Second), 100, live, false) {
		t.Fatal("live stream expired before the idle boundary")
	}
	if !watch.stalled(now.Add(liveProgressTimeout), 100, live, false) {
		t.Fatal("idle live stream did not expire")
	}
}

func TestLiveProgressPreservesLongReplayAndSnapshot(t *testing.T) {
	now := time.Unix(1000, 0)
	for _, fixture := range []struct {
		name     string
		stats    jetstream.Stats
		snapshot bool
	}{
		{"initial planning", jetstream.Stats{}, false},
		{"archive download", jetstream.Stats{SealedTip: 100, PlannedThrough: 50, ResidualGap: 50}, false},
		{"bounded snapshot", jetstream.Stats{SealedTip: 100, PlannedThrough: 100}, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			watch := liveProgressWatch{}
			watch.stalled(now, 10, fixture.stats, fixture.snapshot)
			if watch.stalled(now.Add(24*time.Hour), 10, fixture.stats, fixture.snapshot) {
				t.Fatal("guard interrupted archive or snapshot work")
			}
		})
	}
}

func TestLiveProgressAdvancementRestartsIdleWindow(t *testing.T) {
	now := time.Unix(1000, 0)
	live := jetstream.Stats{SealedTip: 100, PlannedThrough: 100}
	for _, advancement := range []struct {
		name     string
		sequence uint64
		stats    jetstream.Stats
	}{
		{"durable cursor", 101, live},
		{"downloaded page", 100, jetstream.Stats{SealedTip: 100, PlannedThrough: 100, Pages: 1}},
		{"archive cursor", 100, jetstream.Stats{SealedTip: 101, PlannedThrough: 101}},
	} {
		t.Run(advancement.name, func(t *testing.T) {
			watch := liveProgressWatch{}
			watch.stalled(now, 100, live, false)
			later := now.Add(liveProgressTimeout)
			if watch.stalled(later, advancement.sequence, advancement.stats, false) || watch.stalled(later.Add(time.Minute), advancement.sequence, advancement.stats, false) {
				t.Fatal("progress did not restart idle window")
			}
		})
	}
}

func TestLiveProgressWatchCancelsWithReconnectCause(t *testing.T) {
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	ticks := make(chan time.Time, 2)
	now := time.Unix(1000, 0)
	ticks <- now
	ticks <- now.Add(liveProgressTimeout)
	watchLiveProgress(ctx, ticks, func() uint64 { return 100 }, func() jetstream.Stats {
		return jetstream.Stats{SealedTip: 100, PlannedThrough: 100}
	}, false, cancel)
	if !errors.Is(context.Cause(ctx), errLiveProgressStalled) {
		t.Fatalf("cancellation cause = %v", context.Cause(ctx))
	}
}
