package operationsapi

import (
	"context"
	"time"
)

type RetentionRound struct {
	Deleted int64
	Calls   int
	Drained bool
}

func RunRetentionRound(ctx context.Context, cleanup func(context.Context, time.Time, int) (int64, error), now func() time.Time) (RetentionRound, error) {
	round := RetentionRound{}
	for call := 1; call <= 10; call++ {
		if e := ctx.Err(); e != nil {
			return round, e
		}
		n, e := cleanup(ctx, now(), 1000)
		if e != nil {
			return round, e
		}
		round.Deleted += n
		round.Calls = call
		if n == 0 {
			round.Drained = true
			return round, nil
		}
	}
	return round, nil
}
func RetentionFailureDelay(failures int) time.Duration {
	return []time.Duration{5, 10, 20, 40, 60}[max(0, min(failures-1, 4))] * time.Second
}
func sleepContext(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
