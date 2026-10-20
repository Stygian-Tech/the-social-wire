package publicationcore

import (
	"context"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type getterFunc func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error)

func (f getterFunc) Get(ctx context.Context, url string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
	return f(ctx, url, h, max, redirects)
}
func TestEnrollUsesPublicBoundedForwardPaginationAndFullFailure(t *testing.T) {
	db := fixtureDB(t)
	did := fmt.Sprintf("did:web:enroll%d.publisher.social", time.Now().UnixNano())
	ctx := context.Background()
	at := time.Now().UTC()
	t.Cleanup(func() { db.Exec(`DELETE FROM content_items WHERE author_did=$1`, did) })
	var mu sync.Mutex
	requests := []url.Values{}
	getter := getterFunc(func(ctx context.Context, target string, h http.Header, max, redirects int) (int, http.Header, []byte, error) {
		if h.Get("Authorization") != "" || h.Get("DPoP") != "" || redirects != 0 {
			t.Error("public PDS auth or redirect leak")
		}
		if strings.Contains(target, "/.well-known/did.json") {
			return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, did)), nil
		}
		u, _ := url.Parse(target)
		q := u.Query()
		mu.Lock()
		requests = append(requests, q)
		mu.Unlock()
		if q.Get("collection") == "site.standard.entry" {
			return 200, nil, []byte(`{"records":[]}`), nil
		}
		if q.Get("reverse") == "true" {
			return 400, nil, []byte(`{"error":"InvalidRequest","message":"reverse pagination not supported"}`), nil
		}
		key := "a"
		cursor := `,"cursor":"next"`
		if q.Get("cursor") == "next" {
			key = "b"
			cursor = ""
		}
		body := fmt.Sprintf(`{"records":[{"uri":%q,"cid":"fixture","value":{"$type":"site.standard.document","title":"Fixture","publishedAt":%q,"textContent":"Content"}}]%s}`, "at://"+did+"/site.standard.document/"+key, at.Format(time.RFC3339), cursor)
		return 200, nil, []byte(body), nil
	})
	pds := &thinappviewcore.PDSClient{HTTP: getter, PLCBase: "https://plc.fixture"}
	enroll := Enroller{DB: db, PDS: pds, HTTP: getter, Projection: &appviewworkercore.EventProjectorRuntime{DB: db, PDS: pds, Counters: thinappviewcore.CounterStore{DB: db}}, MaximumRecords: 5, Concurrency: 1}
	n, err := enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, false)
	if err != nil || n != 2 {
		t.Fatalf("full indexed %d %v", n, err)
	}
	for _, q := range requests {
		if q.Get("collection") == "site.standard.document" && q.Get("limit") != "1" {
			t.Fatal("exceeded hosted document cap")
		}
	}
	enroll.MaximumRecords = 1
	n, err = enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, false)
	if err == nil || n != 1 {
		t.Fatalf("full cap concealed incomplete count=%d err=%v", n, err)
	}
	enroll.MaximumRecords = 5
	n, err = enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, true)
	if err != nil || n != 1 {
		t.Fatalf("recent pagination blocked/expanded %d %v", n, err)
	}
	enroll.MaximumRecords = 1
	n, err = enroll.Enroll(ctx, gatewaycore.AuthContext{DID: did}, []string{did}, nil, true)
	if err == nil || n != 1 || !strings.Contains(err.Error(), "record cap reached") {
		t.Fatalf("recent cap concealed incomplete count=%d err=%v", n, err)
	}
}

func TestRecentEnrollPropagatesAuthorFailures(t *testing.T) {
	for _, failure := range []string{"resolution", "fetch", "none"} {
		t.Run(failure, func(t *testing.T) {
			did := "did:web:recent-" + failure + ".publisher.social"
			upstreamErr := errors.New("upstream unavailable")
			pages := 0
			getter := getterFunc(func(_ context.Context, target string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
				if strings.Contains(target, "/.well-known/did.json") {
					if failure == "resolution" {
						return 0, nil, nil, upstreamErr
					}
					return 200, nil, []byte(fmt.Sprintf(`{"id":%q,"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.publisher.social"}]}`, did)), nil
				}
				pages++
				if failure == "fetch" {
					return 0, nil, nil, upstreamErr
				}
				return 200, nil, []byte(`{"records":[]}`), nil
			})
			enroll := Enroller{PDS: &thinappviewcore.PDSClient{HTTP: getter}, HTTP: getter, Concurrency: 1}
			n, err := enroll.Enroll(context.Background(), gatewaycore.AuthContext{}, []string{did}, nil, true)
			if n != 0 {
				t.Fatalf("indexed %d empty records", n)
			}
			if failure == "none" {
				if err != nil || pages != 2 {
					t.Fatalf("happy path pages=%d err=%v", pages, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), "PDS enrollment incomplete") {
				t.Fatalf("concealed %s failure: %v", failure, err)
			} else if failure == "fetch" && !errors.Is(err, upstreamErr) {
				t.Fatalf("lost upstream error: %v", err)
			}
		})
	}
}

type enrollerSubscriptionRepo struct {
	repoFixture
	err   error
	calls int
}

func (r *enrollerSubscriptionRepo) ListRecords(_ context.Context, _ string, collection, _ string, _ int, _ bool) (gatewaycore.RepoPage, error) {
	if collection != thinappviewcore.RSSSubscriptionCollection {
		return gatewaycore.RepoPage{}, fmt.Errorf("unexpected collection %s", collection)
	}
	r.calls++
	return gatewaycore.RepoPage{}, r.err
}

func TestEnrollAttemptsRSSAfterAuthorFailure(t *testing.T) {
	for _, recent := range []bool{true, false} {
		t.Run(fmt.Sprintf("recent=%t", recent), func(t *testing.T) {
			rssErr := errors.New("RSS subscriptions unavailable")
			repo := &enrollerSubscriptionRepo{err: rssErr}
			enroll := Enroller{Repo: repo, RSS: &thinappviewcore.RSSIngestion{}}
			n, err := enroll.Enroll(context.Background(), gatewaycore.AuthContext{DID: "did:plc:viewer"}, []string{"invalid-author"}, []string{"https://publisher.social/feed"}, recent)
			if n != 0 || repo.calls != 1 {
				t.Fatalf("RSS not attempted: indexed=%d calls=%d err=%v", n, repo.calls, err)
			}
			if !errors.Is(err, rssErr) || !strings.Contains(err.Error(), "PDS enrollment incomplete") || !strings.Contains(err.Error(), "invalid enrollment author") {
				t.Fatalf("lost aggregated source errors: %v", err)
			}
		})
	}
}

func TestRecentEnrollPreservesCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	did := "did:web:recent-cancel.publisher.social"
	getter := getterFunc(func(_ context.Context, _ string, _ http.Header, _, _ int) (int, http.Header, []byte, error) {
		cancel()
		return 0, nil, nil, ctx.Err()
	})
	repo := &enrollerSubscriptionRepo{}
	enroll := Enroller{PDS: &thinappviewcore.PDSClient{HTTP: getter}, Repo: repo, RSS: &thinappviewcore.RSSIngestion{}}
	n, err := enroll.Enroll(ctx, gatewaycore.AuthContext{}, []string{did}, []string{"https://publisher.social/feed"}, true)
	if n != 0 || !errors.Is(err, context.Canceled) || repo.calls != 0 {
		t.Fatalf("cancellation indexed=%d RSS calls=%d err=%v", n, repo.calls, err)
	}
}

func TestRetryDelayPolicy(t *testing.T) {
	at := time.Now()
	for _, tt := range []struct {
		raw     string
		attempt int
		want    time.Duration
	}{{"2", 1, 2400 * time.Millisecond}, {"900", 1, 30 * time.Second}, {"nonsense", 3, 4800 * time.Millisecond}, {at.Add(-time.Minute).UTC().Format(http.TimeFormat), 1, 0}} {
		if got := retryDelay(tt.raw, tt.attempt, at, .2); got != tt.want {
			t.Fatalf("delay %q %v want %v", tt.raw, got, tt.want)
		}
	}
}
