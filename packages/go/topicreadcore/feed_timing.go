package topicreadcore

import (
	"context"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

type feedPhaseObserverKey struct{}

// WithFeedPhaseObserver records bounded phase timings without attaching viewer data.
func WithFeedPhaseObserver(ctx context.Context, observer func(string, time.Duration)) context.Context {
	return corpuscore.WithQueryObserver(context.WithValue(ctx, feedPhaseObserverKey{}, observer), observer)
}

func ObserveFeedPhase(ctx context.Context, phase string, elapsed time.Duration) {
	if observer, ok := ctx.Value(feedPhaseObserverKey{}).(func(string, time.Duration)); ok && observer != nil {
		observer(phase, elapsed)
	}
}
