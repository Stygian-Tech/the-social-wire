package publicationcore

import (
	"context"
	"errors"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"testing"
	"time"
)

func TestRedisOutageIsDisposableCacheMiss(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), DialTimeout: 20 * time.Millisecond, ReadTimeout: 20 * time.Millisecond, MaxRetries: -1})
	t.Cleanup(func() { client.Close() })
	cache := CacheStore{Redis: socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: client})}
	server.Close()
	at := time.Now()
	if hit, err := cache.Lookup(context.Background(), "viewer", at, false); hit != nil || err != nil {
		t.Fatalf("sidebar outage: %v %v", hit, err)
	}
	if hit, err := cache.CachedPage(context.Background(), "viewer", "publication", 50, at); hit != nil || err != nil {
		t.Fatalf("page outage: %v %v", hit, err)
	}
	if counts, stamp, stale, err := cache.unread(context.Background(), "viewer", []string{"one", "two"}, at); len(counts) != 0 || stamp != nil || stale || err != nil {
		t.Fatalf("unread outage: %v %v", counts, err)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := cache.Lookup(cancelled, "viewer", at, false); !errors.Is(err, context.Canceled) {
		t.Fatal("sidebar cancellation lost", err)
	}
	if _, err := cache.CachedPage(cancelled, "viewer", "publication", 50, at); !errors.Is(err, context.Canceled) {
		t.Fatal("page cancellation lost", err)
	}
	if _, _, _, err := cache.unread(cancelled, "viewer", []string{"one"}, at); !errors.Is(err, context.Canceled) {
		t.Fatal("unread cancellation lost", err)
	}
}
