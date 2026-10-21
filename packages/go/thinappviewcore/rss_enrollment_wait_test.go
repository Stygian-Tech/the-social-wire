package thinappviewcore

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

func TestRSSExplicitWaitRevalidatesAfterOwnerCompletion(t *testing.T) {
	db := inboxDatabase(t)
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	feed := fmt.Sprintf("https://lease-%d.invalid/rss", time.Now().UnixNano())
	t.Cleanup(func() {
		db.Exec("DELETE FROM content_items WHERE publication_site=$1", feed)
		db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=$1", feed)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	contended := make(chan struct{})
	var contentions atomic.Int32
	cache := &ProjectionCache{Redis: client, Namespace: socialwireredis.NewKeyNamespace("dev", ""), LockTelemetry: func(_, outcome string) {
		if outcome == "contended" {
			if contentions.Add(1) == 2 {
				close(contended)
			}
		}
	}}
	started, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	ingestion := RSSIngestion{DB: db, Cache: cache, HTTP: fixtureGetter(func(ctx context.Context, _ string, headers http.Header, _, _ int) (int, http.Header, []byte, error) {
		if calls.Add(1) == 1 {
			close(started)
			select {
			case <-release:
			case <-ctx.Done():
				return 0, nil, nil, ctx.Err()
			}
			return 200, http.Header{"Etag": {"fixture"}}, []byte(`<rss><channel><item><title>Saved</title><guid>one</guid></item></channel></rss>`), nil
		}
		if headers.Get("If-None-Match") != "fixture" {
			t.Error("did not load owner's persisted validators")
		}
		return 304, nil, nil, nil
	})}
	ownerDone := make(chan struct{})
	go func() {
		defer close(ownerDone)
		if n, err := ingestion.Ingest(ctx, feed); n != 1 || err != nil {
			t.Errorf("owner %d %v", n, err)
		}
	}()
	<-started
	if n, err := ingestion.Ingest(ctx, feed); n != 0 || err != nil {
		t.Fatalf("background contention %d %v", n, err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if n, err := ingestion.IngestAndWait(ctx, feed); n != 0 || err != nil {
			t.Errorf("conditional revalidation %d %v", n, err)
		}
	}()
	<-contended
	select {
	case <-done:
		t.Fatal("explicit refresh completed before owner")
	default:
	}
	close(release)
	<-ownerDone
	<-done
	if calls.Load() != 2 {
		t.Fatalf("HTTP calls %d", calls.Load())
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM content_items WHERE publication_site=$1", feed).Scan(&count); err != nil || count != 1 {
		t.Fatalf("persisted=%d err=%v", count, err)
	}
}

func TestRSSExplicitLeaseWaitCancellation(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	contended := make(chan struct{}, 1)
	cache := &ProjectionCache{Redis: client, Namespace: socialwireredis.NewKeyNamespace("dev", ""), LockTelemetry: func(_, outcome string) {
		if outcome == "contended" {
			select {
			case contended <- struct{}{}:
			default:
			}
		}
	}}
	feed := "https://cancel-lease.invalid/rss"
	owner, err := cache.AcquireRefreshLease(context.Background(), "rss", feed, time.Minute)
	if err != nil || owner == nil {
		t.Fatalf("owner %v %v", owner, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := (RSSIngestion{Cache: cache}).IngestAndWait(ctx, feed); done <- err }()
	<-contended
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("wait cancellation %v", err)
	}
	if ok, err := cache.RenewRefreshLease(context.Background(), *owner); err != nil || !ok {
		t.Fatalf("waiter changed owner lease: %t %v", ok, err)
	}
}

func TestRSSExplicitFailuresAreErrorsWhileBackgroundRemainsBestEffort(t *testing.T) {
	db := inboxDatabase(t)
	for _, failure := range []string{"transport", "status", "parse"} {
		for _, explicit := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/explicit=%t", failure, explicit), func(t *testing.T) {
				feed := fmt.Sprintf("https://failure-%s-%t-%d.invalid/rss", failure, explicit, time.Now().UnixNano())
				t.Cleanup(func() { db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=$1", feed) })
				calls := 0
				upstreamErr := errors.New("upstream timeout")
				r := RSSIngestion{DB: db, HTTP: fixtureGetter(func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error) {
					calls++
					switch failure {
					case "transport":
						return 0, nil, nil, upstreamErr
					case "status":
						return 503, nil, nil, nil
					default:
						return 200, nil, []byte("<invalid"), nil
					}
				})}
				invoke := r.Ingest
				if explicit {
					invoke = r.IngestAndWait
				}
				if n, err := invoke(context.Background(), feed); n != 0 || (err != nil) != explicit || explicit && failure == "transport" && !errors.Is(err, upstreamErr) {
					t.Fatalf("first result %d %v", n, err)
				}
				metadata, err := (RSSStore{DB: db}).Metadata(context.Background(), feed)
				if err != nil || metadata == nil || metadata.ConsecutiveErrors != 1 || metadata.BackoffUntil == nil {
					t.Fatalf("failure metadata %+v %v", metadata, err)
				}
				if n, err := invoke(context.Background(), feed); n != 0 || (err != nil) != explicit {
					t.Fatalf("backoff result %d %v", n, err)
				}
				if calls != 1 {
					t.Fatalf("backoff fetched %d times", calls)
				}
			})
		}
	}
}

func TestRSSExplicitWaitDoesNotCompleteSuccessfullyAfterOwnerFailure(t *testing.T) {
	db := inboxDatabase(t)
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	feed := fmt.Sprintf("https://failed-owner-%d.invalid/rss", time.Now().UnixNano())
	t.Cleanup(func() { db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=$1", feed) })
	contended := make(chan struct{}, 1)
	cache := &ProjectionCache{Redis: client, Namespace: socialwireredis.NewKeyNamespace("dev", ""), LockTelemetry: func(_, outcome string) {
		if outcome == "contended" {
			select {
			case contended <- struct{}{}:
			default:
			}
		}
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started, release, ownerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	r := RSSIngestion{DB: db, Cache: cache, HTTP: fixtureGetter(func(ctx context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		close(started)
		select {
		case <-release:
		case <-ctx.Done():
			return 0, nil, nil, ctx.Err()
		}
		return 503, nil, nil, nil
	})}
	go func() {
		defer close(ownerDone)
		if _, err := r.Ingest(ctx, feed); err != nil {
			t.Error(err)
		}
	}()
	<-started
	done := make(chan error, 1)
	go func() { _, err := r.IngestAndWait(ctx, feed); done <- err }()
	<-contended
	select {
	case err := <-done:
		t.Fatalf("completed before owner: %v", err)
	default:
	}
	close(release)
	<-ownerDone
	if err := <-done; err == nil || !strings.Contains(err.Error(), "backoff") {
		t.Fatalf("owner failure was concealed: %v", err)
	}
}
