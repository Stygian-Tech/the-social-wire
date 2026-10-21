package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type rssEnrollmentRepo struct {
	repoFixture
	records []gatewaycore.RepoRecord
	calls   atomic.Int32
}

func (r *rssEnrollmentRepo) ListRecords(_ context.Context, _ string, collection, cursor string, _ int, _ bool) (gatewaycore.RepoPage, error) {
	if collection != thinappviewcore.RSSSubscriptionCollection {
		return gatewaycore.RepoPage{}, fmt.Errorf("unexpected collection %s", collection)
	}
	r.calls.Add(1)
	start := 0
	if cursor != "" {
		_, _ = fmt.Sscanf(cursor, "%d", &start)
	}
	end := min(start+50, len(r.records))
	page := gatewaycore.RepoPage{Records: r.records[start:end]}
	if end < len(r.records) {
		page.Cursor = fmt.Sprint(end)
	}
	return page, nil
}

func rssEnrollmentFixture(tb testing.TB, count int) (*sql.DB, *rssEnrollmentRepo, []string) {
	tb.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		tb.Skip("canonical PostgreSQL fixture required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		tb.Fatal(err)
	}
	db.SetMaxOpenConns(2)
	repo := &rssEnrollmentRepo{}
	feeds := make([]string, count)
	nonce := time.Now().UnixNano()
	for i := range feeds {
		feeds[i] = fmt.Sprintf("https://enroll-%d-%d.invalid/rss", nonce, i)
		repo.records = append(repo.records, gatewaycore.RepoRecord{Value: map[string]json.RawMessage{"feedUrl": json.RawMessage(fmt.Sprintf("%q", feeds[i]))}})
	}
	tb.Cleanup(func() {
		db.Exec("DELETE FROM content_items WHERE publication_site=ANY($1::text[])", feeds)
		db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=ANY($1::text[])", feeds)
		db.Close()
	})
	return db, repo, feeds
}

var enrollmentRSSBody = []byte(`<rss version="2.0"><channel><title>Fixture</title><item><title>Story</title><guid>one</guid><link>https://article.invalid/story</link></item></channel></rss>`)

func TestRSS78SourcesNormalizeAuthorizeOnceAndAwaitAll(t *testing.T) {
	db, repo, feeds := rssEnrollmentFixture(t, 78)
	repo.records = append(repo.records, gatewaycore.RepoRecord{Value: map[string]json.RawMessage{"feedUrl": json.RawMessage(fmt.Sprintf("%q", feeds[0]+"#duplicate"))}})
	requested := append(append([]string{}, feeds...), feeds[0]+"#fragment", "https://unauthorized.invalid/rss")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started, release := make(chan struct{}, 78), make(chan struct{})
	var calls atomic.Int32
	getter := getterFunc(func(ctx context.Context, target string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		calls.Add(1)
		started <- struct{}{}
		select {
		case <-release:
		case <-ctx.Done():
			return 0, nil, nil, ctx.Err()
		}
		return 200, nil, enrollmentRSSBody, nil
	})
	e := &Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
	done := make(chan struct{})
	go func() {
		defer close(done)
		n, err := e.Enroll(ctx, gatewaycore.AuthContext{DID: "viewer"}, nil, requested, true)
		if n != 78 || err != nil {
			t.Errorf("enroll %d %v", n, err)
		}
	}()
	for i := 0; i < maximumRSSConcurrency; i++ {
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("workers did not start", ctx.Err())
		}
	}
	select {
	case <-done:
		t.Error("enrollment completed before source work")
	default:
	}
	close(release)
	<-done
	if calls.Load() != 78 || repo.calls.Load() != 2 {
		t.Fatalf("fetches=%d subscription pages=%d", calls.Load(), repo.calls.Load())
	}
	var indexed int
	if err := db.QueryRow("SELECT COUNT(*) FROM content_items WHERE publication_site=ANY($1::text[])", feeds).Scan(&indexed); err != nil || indexed != 78 {
		t.Fatalf("persisted=%d err=%v", indexed, err)
	}
}

func TestEnrollOverlapsSourcesAndJoinsAuthorOnRSSFailure(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started, release := make(chan struct{}), make(chan struct{})
	authorErr, rssErr := errors.New("author unavailable"), errors.New("subscriptions unavailable")
	getter := getterFunc(func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error) {
		close(started)
		<-release
		return 0, nil, nil, authorErr
	})
	repo := &blockingRSSErrorRepo{started: started, err: rssErr, observed: make(chan struct{})}
	e := Enroller{Repo: repo, PDS: &thinappviewcore.PDSClient{HTTP: getter}, RSS: &thinappviewcore.RSSIngestion{}}
	done := make(chan error, 1)
	go func() {
		_, err := e.Enroll(ctx, gatewaycore.AuthContext{DID: "viewer"}, []string{"did:web:overlap.publisher.social"}, []string{"https://feed.invalid/rss"}, true)
		done <- err
	}()
	select {
	case <-repo.overlapped():
	case <-ctx.Done():
		t.Fatal("sources did not overlap")
	}
	select {
	case err := <-done:
		t.Fatalf("did not await author: %v", err)
	default:
	}
	close(release)
	err := <-done
	if !errors.Is(err, rssErr) || !strings.Contains(err.Error(), "PDS enrollment incomplete") {
		t.Fatalf("source error lost: %v", err)
	}
}

func TestRSSWorkersDoNotQueueIndependentHostBehindSlowHost(t *testing.T) {
	db, repo, _ := rssEnrollmentFixture(t, 0)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	release, independent := make(chan struct{}), make(chan struct{}, 32)
	feeds := make([]string, 0, 64)
	for i := 0; i < 32; i++ {
		feeds = append(feeds, fmt.Sprintf("https://a-slow.invalid/%d", i))
	}
	for i := 0; i < 32; i++ {
		feeds = append(feeds, fmt.Sprintf("https://z-independent.invalid/%d", i))
	}
	getter := getterFunc(func(ctx context.Context, target string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		parsed, _ := url.Parse(target)
		if parsed.Hostname() == "a-slow.invalid" {
			select {
			case <-release:
			case <-ctx.Done():
				return 0, nil, nil, ctx.Err()
			}
		} else {
			independent <- struct{}{}
		}
		return 304, nil, nil, nil
	})
	t.Cleanup(func() { db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=ANY($1::text[])", feeds) })
	e := Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := e.ingestFeeds(ctx, feeds, true); err != nil {
			t.Error(err)
		}
	}()
	for i := 0; i < 32; i++ {
		select {
		case <-independent:
		case <-ctx.Done():
			t.Fatalf("independent host starved after %d/32 feeds while slow host was blocked", i)
		}
	}
	select {
	case <-done:
		t.Error("did not await slow host")
	default:
	}
	close(release)
	<-done
}

func TestRSSAdmissionIsSharedAcrossEnrollerInstances(t *testing.T) {
	db, repo, feeds := rssEnrollmentFixture(t, 40)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started, release := make(chan struct{}, 40), make(chan struct{})
	getter := getterFunc(func(ctx context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		started <- struct{}{}
		select {
		case <-release:
		case <-ctx.Done():
			return 0, nil, nil, ctx.Err()
		}
		return 200, nil, enrollmentRSSBody, nil
	})
	done := make(chan struct{}, 2)
	for i := 0; i < 2; i++ {
		e := &Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
		go func(feeds []string) {
			defer func() { done <- struct{}{} }()
			if n, err := e.Enroll(ctx, gatewaycore.AuthContext{DID: "viewer"}, nil, feeds, true); n != 20 || err != nil {
				t.Errorf("enroll %d %v", n, err)
			}
		}(feeds[i*20 : (i+1)*20])
	}
	for i := 0; i < 16; i++ {
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("workers not admitted")
		}
	}
	sharedRSSAdmission.mu.Lock()
	if sharedRSSAdmission.active != 16 {
		t.Errorf("global active=%d", sharedRSSAdmission.active)
	}
	sharedRSSAdmission.mu.Unlock()
	select {
	case <-started:
		t.Error("instances multiplied global admission")
	default:
	}
	close(release)
	<-done
	<-done
}

func TestRSSEnrollmentCancellationWaitsForStartedWork(t *testing.T) {
	db, repo, feeds := rssEnrollmentFixture(t, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started, canceled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	getter := getterFunc(func(ctx context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		close(started)
		<-ctx.Done()
		close(canceled)
		<-release
		return 0, nil, nil, ctx.Err()
	})
	e := Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
	done := make(chan error, 1)
	go func() {
		n, err := e.Enroll(ctx, gatewaycore.AuthContext{DID: "viewer"}, nil, feeds, true)
		if n != 0 {
			t.Errorf("canceled count=%d", n)
		}
		done <- err
	}()
	<-started
	cancel()
	<-canceled
	select {
	case err := <-done:
		t.Fatalf("returned before started work joined: %v", err)
	default:
	}
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
}

func TestEnrollRetainsSuccessfulRSSCountOnAuthorFailure(t *testing.T) {
	db, repo, feeds := rssEnrollmentFixture(t, 1)
	getter := getterFunc(func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error) {
		return 200, nil, enrollmentRSSBody, nil
	})
	e := Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
	n, err := e.Enroll(context.Background(), gatewaycore.AuthContext{DID: "viewer"}, []string{"invalid-author"}, feeds, true)
	if n != 1 || err == nil || !strings.Contains(err.Error(), "PDS enrollment incomplete") {
		t.Fatalf("partial count/error %d %v", n, err)
	}
}

func TestAuthorCancellationRetainsEarlierErrorAndPartialCount(t *testing.T) {
	db, _, _ := rssEnrollmentFixture(t, 0)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	did := fmt.Sprintf("did:web:a-success-%d.publisher.social", time.Now().UnixNano())
	blocked := "did:web:z-blocked.publisher.social"
	started := make(chan struct{})
	t.Cleanup(func() { db.Exec("DELETE FROM content_items WHERE author_did=$1", did) })
	getter := getterFunc(func(ctx context.Context, target string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		if strings.Contains(target, "z-blocked.publisher.social") {
			close(started)
			<-ctx.Done()
			return 0, nil, nil, ctx.Err()
		}
		if strings.Contains(target, "/.well-known/did.json") {
			return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, did)), nil
		}
		parsed, _ := url.Parse(target)
		if parsed.Query().Get("collection") == "site.standard.entry" {
			return 200, nil, []byte(`{"records":[]}`), nil
		}
		return 200, nil, []byte(fmt.Sprintf(`{"records":[{"uri":%q,"cid":"fixture","value":{"title":"Counted","publishedAt":%q}}]}`, "at://"+did+"/site.standard.document/one", time.Now().UTC().Format(time.RFC3339))), nil
	})
	pds := &thinappviewcore.PDSClient{HTTP: getter}
	e := NewEnroller(db, nil, pds, getter, nil, map[string]string{"THIN_APPVIEW_MAX_ENROLL_CONCURRENCY": "1"})
	type result struct {
		n   int
		err error
	}
	done := make(chan result, 1)
	go func() {
		n, err := e.Enroll(ctx, gatewaycore.AuthContext{}, []string{"!invalid-author", did, blocked}, nil, true)
		done <- result{n, err}
	}()
	<-started
	cancel()
	r := <-done
	if r.n != 1 || !errors.Is(r.err, context.Canceled) || !strings.Contains(r.err.Error(), "invalid enrollment author") {
		t.Fatalf("partial/cancel result %d %v", r.n, r.err)
	}
}

type joinedEnrollmentContext struct {
	context.Context
	calls  atomic.Int32
	joined chan struct{}
}

func (c *joinedEnrollmentContext) Done() <-chan struct{} {
	// A joined call waits on this context before its owner is released.
	if c.calls.Add(1) == 1 {
		close(c.joined)
	}
	return c.Context.Done()
}

func TestRSSSameFeedAcrossEnrollersJoinsCompletedCount(t *testing.T) {
	for _, abort := range []bool{false, true} {
		t.Run(fmt.Sprintf("abortOwner=%t", abort), func(t *testing.T) {
			db, repo, feeds := rssEnrollmentFixture(t, 1)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			ownerCtx, abortOwner := context.WithCancel(ctx)
			defer abortOwner()
			started, release := make(chan struct{}), make(chan struct{})
			var calls atomic.Int32
			getter := getterFunc(func(ctx context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
				if calls.Add(1) == 1 {
					close(started)
					select {
					case <-release:
					case <-ctx.Done():
						return 0, nil, nil, ctx.Err()
					}
				} else if !abort {
					t.Error("same-feed ingestion duplicated")
				}
				return 200, nil, enrollmentRSSBody, nil
			})
			done := make(chan struct{}, 2)
			run := func(ctx context.Context, expectCanceled bool) {
				defer func() { done <- struct{}{} }()
				e := Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
				n, err := e.Enroll(ctx, gatewaycore.AuthContext{DID: "viewer"}, nil, feeds, true)
				if expectCanceled {
					if n != 0 || !errors.Is(err, context.Canceled) {
						t.Errorf("aborted owner %d %v", n, err)
					}
				} else if n != 1 || err != nil {
					t.Errorf("live enrollment %d %v", n, err)
				}
			}
			go run(ownerCtx, abort)
			<-started
			joined := &joinedEnrollmentContext{Context: ctx, joined: make(chan struct{})}
			go run(joined, false)
			select {
			case <-joined.joined:
			case <-ctx.Done():
				t.Fatal("join did not start")
			}
			select {
			case <-done:
				t.Error("join returned before owner")
			default:
			}
			if abort {
				abortOwner()
			} else {
				close(release)
			}
			<-done
			<-done
			want := int32(1)
			if abort {
				want = 2
			}
			if calls.Load() != want {
				t.Fatalf("HTTP calls %d want %d", calls.Load(), want)
			}
			var persisted int
			if err := db.QueryRow("SELECT COUNT(*) FROM content_items WHERE publication_site=$1", feeds[0]).Scan(&persisted); err != nil || persisted != 1 {
				t.Fatalf("persisted=%d err=%v", persisted, err)
			}
		})
	}
}

type blockingRSSErrorRepo struct {
	repoFixture
	started  <-chan struct{}
	err      error
	observed chan struct{}
}

func (r *blockingRSSErrorRepo) overlapped() <-chan struct{} { return r.observed }
func (r *blockingRSSErrorRepo) ListRecords(ctx context.Context, _ string, _ string, _ string, _ int, _ bool) (gatewaycore.RepoPage, error) {
	select {
	case <-r.started:
	case <-ctx.Done():
		return gatewaycore.RepoPage{}, ctx.Err()
	}
	close(r.observed)
	return gatewaycore.RepoPage{}, r.err
}

// Same feed set, HTTP delay, ingestion implementation, and PostgreSQL schema.
// Worker count 1 models the former serial RSS loop; 16 measures bounded workers.
// This benchmark makes no hosted latency or acceptance claim.
func BenchmarkRSSEnrollment78Sources(b *testing.B) {
	for _, workers := range []int{1, 16} {
		b.Run(fmt.Sprintf("workers=%d", workers), func(b *testing.B) {
			db, repo, feeds := rssEnrollmentFixture(b, 78)
			getter := getterFunc(func(ctx context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
				timer := time.NewTimer(20 * time.Millisecond)
				defer timer.Stop()
				select {
				case <-ctx.Done():
					return 0, nil, nil, ctx.Err()
				case <-timer.C:
				}
				return 200, nil, enrollmentRSSBody, nil
			})
			e := Enroller{Repo: repo, RSSConcurrency: workers, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				if _, err := db.Exec("DELETE FROM content_items WHERE publication_site=ANY($1::text[])", feeds); err != nil {
					b.Fatal(err)
				}
				if _, err := db.Exec("DELETE FROM rss_feed_fetch_metadata WHERE feed_url=ANY($1::text[])", feeds); err != nil {
					b.Fatal(err)
				}
				b.StartTimer()
				n, err := e.Enroll(context.Background(), gatewaycore.AuthContext{DID: "viewer"}, nil, feeds, true)
				if err != nil || n != 78 {
					b.Fatalf("enroll %d %v", n, err)
				}
			}
		})
	}
}
