package topicreadcore

import (
	"context"
	"encoding/json"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"strings"
	"testing"
	"time"
)

func circleCacheFixture(t *testing.T) *CircleCache {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: 0})
	t.Cleanup(func() { client.Close() })
	return NewCircleCache(socialwireredis.RedisCommands{Client: client}, "test")
}
func TestCircleRedisSwiftEnvelopeAndPrivacyBinding(t *testing.T) {
	cache := circleCacheFixture(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 7, 12, 0, 0, 123456000, time.UTC)
	g := CircleGraph{SnapshotID: "11111111-1111-1111-1111-111111111111", ViewerDID: "did:example:viewer", GeneratedAt: now, DirectMembers: []CircleMember{{ActorDID: "did:example:a", Depth: 1, PathCount: 1, RecentActivityAt: &now}}, OneHopMembers: []CircleMember{}}
	excluded := map[string]bool{g.ViewerDID: true}
	if err := cache.StoreGraph(ctx, g, excluded, now); err != nil {
		t.Fatal(err)
	}
	raw, err := cache.Client.Commands.Get(ctx, cache.key("circle-graph", g.ViewerDID))
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if json.Unmarshal(raw, &document) != nil {
		t.Fatal("invalid envelope")
	}
	snapshot := document["value"].(map[string]any)["snapshot"].(map[string]any)
	if _, ok := snapshot["generatedAt"].(float64); !ok {
		t.Fatal("Swift milliseconds not retained", string(raw))
	}
	if snapshot["directMembers"].([]any)[0].(map[string]any)["depth"] != float64(1) {
		t.Fatal(snapshot)
	}
	loaded, err := cache.LoadGraph(ctx, g.ViewerDID, excluded, now.Add(time.Hour))
	if err != nil || loaded == nil || loaded.GeneratedAt.Sub(now) > time.Microsecond || loaded.GeneratedAt.Sub(now) < -time.Microsecond {
		t.Fatal(loaded, err)
	}
	if loaded, _ = cache.LoadGraph(ctx, g.ViewerDID, map[string]bool{"changed": true}, now); loaded != nil {
		t.Fatal("exclusion mismatch accepted")
	}
	if loaded, _ = cache.LoadGraph(ctx, g.ViewerDID, excluded, now.Add(24*time.Hour)); loaded != nil {
		t.Fatal("hard expired graph accepted")
	}
	hidden := map[string]bool{"a": true}
	if err = cache.StoreEdition(ctx, g.ViewerDID, g.SnapshotID, "generation", "en", hidden, now.Add(time.Minute), []byte(`{"ok":true}`), now); err != nil {
		t.Fatal(err)
	}
	payload, err := cache.CachedEdition(ctx, g.ViewerDID, g.SnapshotID, "generation", "en", hidden, now)
	if err != nil || !strings.Contains(string(payload), "ok") {
		t.Fatal(string(payload), err)
	}
	if payload, _ = cache.CachedEdition(ctx, g.ViewerDID, g.SnapshotID, "generation", "en", nil, now); payload != nil {
		t.Fatal("hidden state mismatch accepted")
	}
	if err = cache.Purge(ctx, g.ViewerDID); err != nil {
		t.Fatal(err)
	}
	if payload, _ = cache.CachedEdition(ctx, g.ViewerDID, g.SnapshotID, "generation", "en", hidden, now); payload != nil {
		t.Fatal("purge did not remove edition")
	}
}
