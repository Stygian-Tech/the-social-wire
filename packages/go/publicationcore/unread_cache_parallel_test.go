package publicationcore

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

func TestUnreadCacheParallelismIsBoundedAndJoinsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var active, maximum, calls atomic.Int32
	started := make(chan struct{}, 8)
	done := make(chan error, 1)
	go func() {
		done <- parallelUnreadCache(ctx, 596, func(int) error {
			calls.Add(1)
			n := active.Add(1)
			defer active.Add(-1)
			for old := maximum.Load(); n > old && !maximum.CompareAndSwap(old, n); old = maximum.Load() {
			}
			started <- struct{}{}
			<-ctx.Done()
			return ctx.Err()
		})
	}()
	for i := 0; i < 8; i++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("cache operations did not run concurrently")
		}
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) || active.Load() != 0 || maximum.Load() != 8 || calls.Load() != 8 {
		t.Fatalf("workers escaped bounds/cancellation: err=%v active=%d max=%d calls=%d", err, active.Load(), maximum.Load(), calls.Load())
	}
}

func TestUnreadRedisRoundTripPreservesLargeViewerSnapshot(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	cache := CacheStore{Redis: socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: client})}
	at := time.Date(2026, time.October, 16, 12, 0, 0, 0, time.UTC)
	counts := map[string]int{}
	ids := []string{}
	for i := 0; i < 596; i++ {
		id := fmt.Sprintf("publication-%03d", i)
		counts[id] = i
		ids = append(ids, id)
	}
	if err := cache.storeUnread(context.Background(), "viewer", counts, at); err != nil {
		t.Fatal(err)
	}
	got, stamp, stale, err := cache.unread(context.Background(), "viewer", ids, at)
	if err != nil || len(got) != len(counts) || stamp == nil || !stamp.Equal(at) || stale {
		t.Fatalf("large cache snapshot: count=%d stamp=%v stale=%v err=%v", len(got), stamp, stale, err)
	}
	for id, want := range counts {
		if got[id] != want {
			t.Fatalf("cache key %s: got=%d want=%d", id, got[id], want)
		}
	}
	other, _, _, err := cache.unread(context.Background(), "other-viewer", ids, at)
	if err != nil || len(other) != 0 {
		t.Fatalf("viewer cache isolation: count=%d err=%v", len(other), err)
	}
}
func TestUnreadCacheParallelismPreservesAllResultsAndErrors(t *testing.T) {
	var visits [596]atomic.Int32
	want := errors.New("cache failure")
	err := parallelUnreadCache(context.Background(), len(visits), func(i int) error {
		visits[i].Add(1)
		if i == 50 {
			return want
		}
		return nil
	})
	if !errors.Is(err, want) {
		t.Fatal(err)
	}
	for i := range visits {
		if visits[i].Load() != 1 {
			t.Fatalf("cache key %d visited %d times", i, visits[i].Load())
		}
	}
}
