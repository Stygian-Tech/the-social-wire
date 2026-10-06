package socialwireredis

import (
	"context"
	"errors"
	"time"

	"github.com/sony/gobreaker/v2"
)

func NewCircuitBreaker() *gobreaker.CircuitBreaker[[]byte] {
	return gobreaker.NewCircuitBreaker[[]byte](gobreaker.Settings{
		Name: "redis-cache", MaxRequests: 1,
		// Use the library's fixed recovery interval instead of a separate
		// exponential cooldown state machine.
		Timeout:     5 * time.Second,
		ReadyToTrip: func(counts gobreaker.Counts) bool { return counts.ConsecutiveFailures >= 3 },
		IsExcluded:  func(err error) bool { return errors.Is(err, context.Canceled) },
	})
}
