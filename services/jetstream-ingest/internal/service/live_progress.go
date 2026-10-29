package service

import (
	"context"
	"errors"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

var errLiveProgressStalled = errors.New("Jetstream live subscription made no durable progress for ten minutes")

const liveProgressTimeout = 10 * time.Minute

// Only a caught-up subscription can expire. Archive planning and downloads retain
// their existing retry/budget boundaries, including downloads that take a long time.
type liveProgressWatch struct {
	pureLive     bool
	lastActivity time.Time
	sequence     uint64
	stats        jetstream.Stats
}

func (w *liveProgressWatch) stalled(now time.Time, sequence uint64, stats jetstream.Stats, snapshotOnly bool) bool {
	progress := sequence != w.sequence || stats.Pages != w.stats.Pages || stats.PlannedThrough != w.stats.PlannedThrough
	w.sequence, w.stats = sequence, stats
	if snapshotOnly || !w.pureLive && stats.SealedTip == 0 || stats.ResidualGap > 0 || progress || w.lastActivity.IsZero() {
		w.lastActivity = now
		return false
	}
	return now.Sub(w.lastActivity) >= liveProgressTimeout
}

func watchLiveProgress(ctx context.Context, ticks <-chan time.Time, sequence func() uint64, stats func() jetstream.Stats, snapshotOnly bool, cancel context.CancelCauseFunc, pureLive ...bool) {
	watch := liveProgressWatch{pureLive: len(pureLive) > 0 && pureLive[0]}
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticks:
			if watch.stalled(now, sequence(), stats(), snapshotOnly) {
				cancel(errLiveProgressStalled)
				return
			}
		}
	}
}
