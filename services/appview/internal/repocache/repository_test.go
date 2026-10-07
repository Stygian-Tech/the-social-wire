package repocache

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func fixture(t *testing.T, status *atomic.Int32, calls *atomic.Int32) (*Repository, *miniredis.Miniredis) {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: -1})
	t.Cleanup(func() { client.Close() })
	base := &gatewaycore.RepoClient{PLCURL: "https://plc.directory", Client: &http.Client{Transport: transport(func(req *http.Request) (*http.Response, error) {
		calls.Add(1)
		return &http.Response{StatusCode: int(status.Load()), Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://publisher.social/"}]}`))}, nil
	})}}
	return New(base, client, "dev"), server
}
func TestSwiftResolutionEnvelopeAndFreshness(t *testing.T) {
	var status, calls atomic.Int32
	status.Store(200)
	r, server := fixture(t, &status, &calls)
	now := time.Now()
	r.Now = func() time.Time { return now }
	did := "did:plc:resolutionfixture"
	for range 2 {
		got, err := r.ResolvePDS(context.Background(), did)
		if err != nil || got != "https://publisher.social" {
			t.Fatal(got, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("fresh cache bypassed", calls.Load())
	}
	key := r.namespace.Key("pds-resolution", nil, []string{did})
	raw, err := server.Get(key)
	if err != nil || !strings.Contains(raw, `"resolved":{"_0":"https://publisher.social"}`) || strings.Contains(key, did) {
		t.Fatal("Swift cache contract", raw, key, err)
	}
	ttl := server.TTL(key)
	if ttl < 6*time.Hour || ttl > 6*time.Hour+36*time.Minute {
		t.Fatal("positive hard expiry jitter", ttl)
	}
	now = now.Add(31 * time.Minute)
	if _, err := r.ResolvePDS(context.Background(), did); err != nil || calls.Load() != 2 {
		t.Fatal("stale owner did not refresh", err, calls.Load())
	}
	if err := r.Invalidate(context.Background(), did); err != nil {
		t.Fatal(err)
	}
	if _, err := r.ResolvePDS(context.Background(), did); err != nil || calls.Load() != 3 {
		t.Fatal("invalidation", err, calls.Load())
	}
}
func TestTransientFailuresNeverBecomeNegativeIdentity(t *testing.T) {
	for _, code := range []int32{429, 500, 503} {
		var status, calls atomic.Int32
		status.Store(code)
		r, server := fixture(t, &status, &calls)
		if _, err := r.ResolvePDS(context.Background(), "did:plc:transient"); err == nil {
			t.Fatal("failure accepted", code)
		}
		if len(server.Keys()) != 0 {
			t.Fatal("transient failure cached", server.Keys())
		}
		status.Store(200)
		if _, err := r.ResolvePDS(context.Background(), "did:plc:transient"); err != nil || calls.Load() != 2 {
			t.Fatal("transient recovery", err)
		}
	}
	var status, calls atomic.Int32
	status.Store(404)
	r, server := fixture(t, &status, &calls)
	now := time.Now()
	r.Now = func() time.Time { return now }
	for range 2 {
		if _, err := r.ResolvePDS(context.Background(), "did:plc:missing"); !errors.Is(err, gatewaycore.ErrAuthentication) {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("negative cache bypassed")
	}
	raw, _ := server.Get(r.namespace.Key("pds-resolution", nil, []string{"did:plc:missing"}))
	if !strings.Contains(raw, `"unresolved":{}`) {
		t.Fatal(raw)
	}
	now = now.Add(61 * time.Second)
	status.Store(200)
	if _, err := r.ResolvePDS(context.Background(), "did:plc:missing"); err != nil || calls.Load() != 2 {
		t.Fatal("negative cache did not refresh", err)
	}
}
func TestLeaseContentionCancellationAndOwnerFence(t *testing.T) {
	var status, calls atomic.Int32
	status.Store(200)
	r, server := fixture(t, &status, &calls)
	ctx := context.Background()
	did := "did:plc:contended"
	now := time.Now()
	if err := r.store(ctx, did, "https://stale.publisher.social", now.Add(-31*time.Minute)); err != nil {
		t.Fatal(err)
	}
	owner, err := r.acquire(ctx, did, now)
	if err != nil || owner == "" {
		t.Fatal(owner, err)
	}
	endpoint, err := r.ResolvePDS(ctx, did)
	if err != nil || endpoint != "https://stale.publisher.social" || calls.Load() != 0 {
		t.Fatal("stale contender blocked", endpoint, err)
	}
	server.FastForward(16 * time.Second)
	successor, err := r.acquire(ctx, did, now.Add(16*time.Second))
	if err != nil || successor == "" {
		t.Fatal(err)
	}
	r.release(did, owner)
	if actual, _ := server.Get(r.namespace.Key("lock", []string{"pds-resolution"}, []string{did})); actual != successor {
		t.Fatal("old owner released successor", actual)
	}
	r.release(did, successor)
	miss := "did:plc:missing-contender"
	owner, _ = r.acquire(ctx, miss, now)
	defer r.release(miss, owner)
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := r.ResolvePDS(canceled, miss); !errors.Is(err, context.Canceled) || calls.Load() != 0 {
		t.Fatal("canceled waiter resolved directly", err)
	}
}
func TestRedisFailureBypassesAndMalformedEndpointsFailClosed(t *testing.T) {
	var status, calls atomic.Int32
	status.Store(200)
	r, server := fixture(t, &status, &calls)
	server.Close()
	if endpoint, err := r.ResolvePDS(context.Background(), "did:plc:redis-outage"); err != nil || endpoint != "https://publisher.social" {
		t.Fatal(endpoint, err)
	}
	for _, endpoint := range []string{"https://user:secret@publisher.social", "https://publisher.social?secret=value", "https://publisher.social/#", "http://publisher.social"} {
		if _, err := cachedEndpoint(endpoint); err == nil {
			t.Fatal("invalid cached endpoint admitted", endpoint)
		}
	}
	for _, raw := range []string{`{"resolved":{"_0":null}}`, `{"unresolved":null}`, `{"resolved":{"_0":"https://publisher.social"},"unresolved":{}}`} {
		var value storedResolution
		if json.Unmarshal([]byte(raw), &value) == nil {
			t.Fatal("malformed enum admitted", raw)
		}
	}
}
func TestLocalCacheFallbackKeepsOriginalClientIndependent(t *testing.T) {
	var calls atomic.Int32
	base := &gatewaycore.RepoClient{PLCURL: "https://plc.directory", Client: &http.Client{Transport: transport(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://publisher.social"}]}`))}, nil
	})}}
	r := New(base, nil, "dev")
	ctx := context.Background()
	for range 2 {
		if _, err := r.ResolvePDS(ctx, "did:web:publisher.social"); err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 || base.PDSResolver != nil {
		t.Fatal("original client changed or local cache bypassed")
	}
	if _, err := base.ResolvePDS(ctx, "did:web:publisher.social"); err != nil || calls.Load() != 2 {
		t.Fatal(err)
	}
}

func TestColdContendersUseCompletedResolutionAndRespectEnvironment(t *testing.T) {
	var status, calls atomic.Int32
	status.Store(200)
	r, server := fixture(t, &status, &calls)
	ctx := context.Background()
	did := "did:plc:wait-for-owner"
	owner, err := r.acquire(ctx, did, time.Now())
	if err != nil || owner == "" {
		t.Fatal(err)
	}
	defer r.release(did, owner)
	completed := make(chan error, 1)
	go func() {
		time.Sleep(75 * time.Millisecond)
		completed <- r.store(ctx, did, "https://joined.publisher.social", time.Now())
	}()
	endpoint, err := r.ResolvePDS(ctx, did)
	if err != nil || endpoint != "https://joined.publisher.social" || calls.Load() != 0 {
		t.Fatal("cold contender ignored owner's completed resolution", endpoint, err, calls.Load())
	}
	if err := <-completed; err != nil {
		t.Fatal(err)
	}
	prod := New(r.base, r.redis, "prod")
	if endpoint, err := prod.ResolvePDS(ctx, did); err != nil || endpoint != "https://publisher.social" || calls.Load() != 1 {
		t.Fatal("environment cache crossed", endpoint, err)
	}
	if len(server.Keys()) < 2 {
		t.Fatal("environment namespaces collided")
	}
}
