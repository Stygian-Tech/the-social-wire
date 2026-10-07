package gatewaycore

import (
	"context"
	"sync"
)

// AuthLifetime owns shared discovery and attestation work across HTTP requests.
// A canceled waiter does not cancel other waiters; process shutdown cancels all.
type AuthLifetime struct {
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	closed  bool
	workers sync.WaitGroup
}

func NewAuthLifetime(parent context.Context) *AuthLifetime {
	ctx, cancel := context.WithCancel(parent)
	return &AuthLifetime{ctx: ctx, cancel: cancel}
}
func (l *AuthLifetime) begin() (context.Context, func(), bool) {
	if l == nil {
		return context.Background(), func() {}, true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return l.ctx, func() {}, false
	}
	l.workers.Add(1)
	return l.ctx, l.workers.Done, true
}
func (l *AuthLifetime) Close(ctx context.Context) error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	l.closed = true
	l.cancel()
	l.mu.Unlock()
	joined := make(chan struct{})
	go func() { l.workers.Wait(); close(joined) }()
	select {
	case <-joined:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
