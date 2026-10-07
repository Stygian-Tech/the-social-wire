package socialwireredis

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestRedisTransportCacheRoundTripAndExpiry(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: -1})
	t.Cleanup(func() { _ = client.Close() })
	commands := RedisCommands{Client: client}
	ctx := context.Background()
	cache := NewCacheClient(commands)
	at := time.Unix(100, 0)
	if value, err := LookupValue[string](ctx, cache, "missing", at); err != nil || value.State != Miss {
		t.Fatal(value, err)
	}
	if err := StoreValue(ctx, cache, "entry", "story", CachePolicy{time.Second, 2 * time.Second, 0}, at); err != nil {
		t.Fatal(err)
	}
	if value, err := LookupValue[string](ctx, cache, "entry", at); err != nil || value.State != Fresh || value.Envelope.Value != "story" {
		t.Fatal(value, err)
	}
	if ttl := server.TTL("entry"); ttl != 2*time.Second {
		t.Fatal("transport TTL differs", ttl)
	}
	server.FastForward(2 * time.Second)
	if value, err := LookupValue[string](ctx, cache, "entry", at); err != nil || value.State != Miss {
		t.Fatal(value, err)
	}
	if err := commands.Set(ctx, "delete", []byte("value"), time.Second); err != nil {
		t.Fatal(err)
	}
	if err := commands.Delete(ctx, []string{"delete"}); err != nil || server.Exists("delete") {
		t.Fatal(err)
	}
	if err := commands.Delete(ctx, nil); err != nil {
		t.Fatal(err)
	}
}
