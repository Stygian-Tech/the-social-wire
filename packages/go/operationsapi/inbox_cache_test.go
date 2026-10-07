package operationsapi

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func waitInboxWaiters(t *testing.T, c *InboxObservationCache, count int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		got := 0
		if c.flight != nil {
			got = c.flight.waiters
		}
		c.mu.Unlock()
		if got == count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("waiter registration timed out")
}
func TestInboxCacheCoalescesIndependentCancellationAndCopies(t *testing.T) {
	cache := InboxObservationCache{}
	ctx, cancel := context.WithCancel(context.Background())
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	load := func(ctx context.Context) (map[string]InboxMetrics, error) {
		calls.Add(1)
		close(entered)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return map[string]InboxMetrics{"fixture": {Pending: 1}}, nil
		}
	}
	first := make(chan error, 1)
	go func() { _, err := cache.Value(ctx, load); first <- err }()
	<-entered
	second := make(chan map[string]InboxMetrics, 1)
	go func() {
		value, err := cache.Value(context.Background(), load)
		if err != nil {
			second <- nil
		} else {
			second <- value
		}
	}()
	waitInboxWaiters(t, &cache, 2)
	cancel()
	if err := <-first; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	close(release)
	value := <-second
	if value["fixture"].Pending != 1 || calls.Load() != 1 {
		t.Fatal(value, calls.Load())
	}
	value["fixture"] = InboxMetrics{Pending: 99}
	cached, err := cache.Value(context.Background(), load)
	if err != nil || cached["fixture"].Pending != 1 || calls.Load() != 1 {
		t.Fatal("mutable observation cache leaked", cached, err)
	}
}
func TestInboxCacheWaitsForCanceledLoaderRetirement(t *testing.T) {
	cache := InboxObservationCache{}
	ctx, cancel := context.WithCancel(context.Background())
	entered, canceled, retire := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	load := func(ctx context.Context) (map[string]InboxMetrics, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-ctx.Done()
			close(canceled)
			<-retire
			return nil, ctx.Err()
		}
		return map[string]InboxMetrics{"replacement": {Pending: 2}}, nil
	}
	first := make(chan error, 1)
	go func() { _, err := cache.Value(ctx, load); first <- err }()
	<-entered
	cancel()
	<-first
	<-canceled
	done := make(chan error, 1)
	go func() {
		value, err := cache.Value(context.Background(), load)
		if err == nil && value["replacement"].Pending != 2 {
			err = errors.New("wrong replacement")
		}
		done <- err
	}()
	select {
	case <-done:
		t.Fatal("replacement overlapped retiring loader")
	case <-time.After(10 * time.Millisecond):
	}
	if calls.Load() != 1 {
		t.Fatal("overlapping replacement")
	}
	close(retire)
	if err := <-done; err != nil || calls.Load() != 2 {
		t.Fatal(err, calls.Load())
	}
}
func TestInboxCacheTTLStartsBeforeCollection(t *testing.T) {
	cache := InboxObservationCache{}
	var calls int
	load := func(context.Context) (map[string]InboxMetrics, error) {
		calls++
		cache.mu.Lock()
		cache.flight.started = time.Now().Add(-6 * time.Second)
		cache.mu.Unlock()
		return map[string]InboxMetrics{}, nil
	}
	for range 2 {
		if _, err := cache.Value(context.Background(), load); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 2 {
		t.Fatal("collection refreshed old evidence", calls)
	}
}
