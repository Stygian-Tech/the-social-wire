package operationsapi

import (
	"context"
	"sync"
	"time"
)

type inboxFlight struct {
	done      chan struct{}
	cancel    context.CancelFunc
	waiters   int
	cancelled bool
	started   time.Time
	value     map[string]InboxMetrics
	err       error
}
type InboxObservationCache struct {
	mu      sync.Mutex
	cached  map[string]InboxMetrics
	expires time.Time
	flight  *inboxFlight
}

// Only observational counts are cached; checkpoint, role, and recovery authority remain live.
func (c *InboxObservationCache) Value(ctx context.Context, load func(context.Context) (map[string]InboxMetrics, error)) (map[string]InboxMetrics, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c.mu.Lock()
		if c.cached != nil && time.Now().Before(c.expires) {
			value := cloneInbox(c.cached)
			c.mu.Unlock()
			return value, nil
		}
		flight := c.flight
		if flight != nil && flight.cancelled {
			c.mu.Unlock()
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-flight.done:
				continue
			}
		}
		if flight == nil {
			loadCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
			flight = &inboxFlight{done: make(chan struct{}), cancel: cancel, started: time.Now()}
			c.flight = flight
			go func() {
				value, err := load(loadCtx)
				if err == nil {
					err = loadCtx.Err()
				}
				c.mu.Lock()
				flight.value, flight.err = value, err
				if !flight.cancelled && err == nil {
					c.cached = cloneInbox(value)
					c.expires = flight.started.Add(5 * time.Second)
				}
				if c.flight == flight {
					c.flight = nil
				}
				close(flight.done)
				c.mu.Unlock()
				cancel()
			}()
		}
		flight.waiters++
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			c.mu.Lock()
			flight.waiters--
			if flight.waiters == 0 {
				flight.cancelled = true
				flight.cancel()
			}
			c.mu.Unlock()
			return nil, ctx.Err()
		case <-flight.done:
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if flight.err != nil {
				return nil, flight.err
			}
			return cloneInbox(flight.value), nil
		}
	}
}
func cloneInbox(input map[string]InboxMetrics) map[string]InboxMetrics {
	output := map[string]InboxMetrics{}
	for key, value := range input {
		if value.OldestPendingAt != nil {
			v := *value.OldestPendingAt
			value.OldestPendingAt = &v
		}
		if value.OldestPendingAgeSeconds != nil {
			v := *value.OldestPendingAgeSeconds
			value.OldestPendingAgeSeconds = &v
		}
		output[key] = value
	}
	return output
}
func ageInbox(value InboxMetrics, at time.Time) InboxMetrics {
	if value.OldestPendingAt != nil {
		age := max(0, at.Sub(value.OldestPendingAt.Time).Seconds())
		value.OldestPendingAgeSeconds = &age
	}
	return value
}
