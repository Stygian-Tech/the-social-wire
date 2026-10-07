package thinappviewcore

import (
	"context"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"testing"
	"time"
)

func TestRefreshLeaseTelemetryReportsAcquisitionAndContentionWithoutResourceIDs(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	var events [][2]string
	cache := ProjectionCache{Redis: client, Namespace: socialwireredis.NewKeyNamespace("dev", ""), LockTelemetry: func(operation, outcome string) { events = append(events, [2]string{operation, outcome}) }}
	ctx := context.Background()
	lease, err := cache.AcquireRefreshLease(ctx, "rss_refresh", "https://private.example/feed", time.Minute)
	if err != nil || lease == nil {
		t.Fatalf("lease: %v %v", lease, err)
	}
	second, err := cache.AcquireRefreshLease(ctx, "rss_refresh", "https://private.example/feed", time.Minute)
	if err != nil || second != nil {
		t.Fatalf("contention: %v %v", second, err)
	}
	if len(events) != 2 || events[0] != [2]string{"rss_refresh", "acquired"} || events[1] != [2]string{"rss_refresh", "contended"} {
		t.Fatal(events)
	}
}

func TestProjectionCacheInvalidationPreservesOtherViewersAndEnvironments(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	namespace := socialwireredis.NewKeyNamespace("dev", "")
	cache := ProjectionCache{Redis: client, Namespace: namespace}
	ctx := context.Background()
	key := func(domain string, ids ...string) string { return namespace.Key(domain, nil, ids) }
	target := []string{key("sidebar", "alice"), key("unread", "alice", "pub"), key("firstpage", "pub", "alice")}
	preserved := []string{key("sidebar", "bob"), key("unread", "bob", "pub"), key("firstpage", "pub", "bob"), key("firstpage", "pub", "shared"), socialwireredis.NewKeyNamespace("prod", "").Key("sidebar", nil, []string{"alice"})}
	for _, k := range append(target, preserved...) {
		server.Set(k, "fixture")
	}
	if err := cache.InvalidateViewer(ctx, "alice"); err != nil {
		t.Fatal(err)
	}
	for _, k := range target {
		if server.Exists(k) {
			t.Fatalf("stale viewer cache %s", k)
		}
	}
	for _, k := range preserved {
		if !server.Exists(k) {
			t.Fatalf("lost unrelated cache %s", k)
		}
	}
	if err := cache.InvalidatePublication(ctx, "pub"); err != nil {
		t.Fatal(err)
	}
	if server.Exists(key("firstpage", "pub", "bob")) || server.Exists(key("firstpage", "pub", "shared")) {
		t.Fatal("publication invalidation must clear all viewer pages")
	}
	if !server.Exists(key("sidebar", "bob")) {
		t.Fatal("publication page invalidation must preserve sidebar")
	}
}
