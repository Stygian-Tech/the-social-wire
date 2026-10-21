package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type observedDoneContext struct {
	context.Context
	once     sync.Once
	observed chan struct{}
}

func (c *observedDoneContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.observed) })
	return c.Context.Done()
}

func TestRSSAdmissionBoundsGlobalAndHostLoad(t *testing.T) {
	for _, sameHost := range []bool{false, true} {
		t.Run(fmt.Sprintf("sameHost=%t", sameHost), func(t *testing.T) {
			a := newRSSEnrollmentAdmission()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			started := make(chan struct{}, 78)
			release := make(chan struct{})
			var wg sync.WaitGroup
			for i := 0; i < 78; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					host := fmt.Sprintf("feed-%d.invalid", i)
					if sameHost {
						host = "shared.invalid"
					}
					n, err := a.ingest(ctx, rssEnrollmentKey{feed: fmt.Sprintf("https://%s/%d", host, i)}, func() (int, error) {
						started <- struct{}{}
						select {
						case <-release:
							return 1, nil
						case <-ctx.Done():
							return 0, ctx.Err()
						}
					})
					if err != nil || n != 1 {
						t.Errorf("result %d %v", n, err)
					}
				}(i)
			}
			limit := maximumRSSConcurrency
			if sameHost {
				limit = maximumRSSHostConcurrency
			}
			for i := 0; i < limit; i++ {
				select {
				case <-started:
				case <-ctx.Done():
					t.Fatal("admission did not fill", ctx.Err())
				}
			}
			a.mu.Lock()
			if a.active != limit {
				t.Errorf("active %d, want %d", a.active, limit)
			}
			a.mu.Unlock()
			select {
			case <-started:
				t.Error("admission exceeded bound")
			default:
			}
			close(release)
			wg.Wait()
			a.mu.Lock()
			defer a.mu.Unlock()
			if a.active != 0 || len(a.hosts) != 0 || len(a.calls) != 0 {
				t.Fatal("admission leaked work")
			}
		})
	}
}

func TestRSSAdmissionJoinReturnsOwnerCountAndError(t *testing.T) {
	a := newRSSEnrollmentAdmission()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	key := rssEnrollmentKey{feed: "https://join.invalid/feed"}
	started, release, ownerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	wantErr := errors.New("partial ingestion")
	go func() {
		defer close(ownerDone)
		n, err := a.ingest(ctx, key, func() (int, error) { close(started); <-release; return 7, wantErr })
		if n != 7 || !errors.Is(err, wantErr) {
			t.Errorf("owner result %d %v", n, err)
		}
	}()
	<-started
	joined := &observedDoneContext{Context: ctx, observed: make(chan struct{})}
	joinDone := make(chan struct{})
	go func() {
		defer close(joinDone)
		n, err := a.ingest(joined, key, func() (int, error) { t.Error("joined work duplicated"); return 0, nil })
		if n != 7 || !errors.Is(err, wantErr) {
			t.Errorf("joined result %d %v", n, err)
		}
	}()
	<-joined.observed
	select {
	case <-joinDone:
		t.Fatal("join completed before owner")
	default:
	}
	close(release)
	<-ownerDone
	<-joinDone
}

func TestRSSAdmissionCanceledJoinDoesNotCompleteOrCancelOwner(t *testing.T) {
	a := newRSSEnrollmentAdmission()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	key := rssEnrollmentKey{feed: "https://cancel-join.invalid/feed"}
	started, release, ownerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(ownerDone)
		n, err := a.ingest(ctx, key, func() (int, error) { close(started); <-release; return 3, nil })
		if n != 3 || err != nil {
			t.Errorf("owner result %d %v", n, err)
		}
	}()
	<-started
	joinCtx, cancelJoin := context.WithCancel(ctx)
	joined := &observedDoneContext{Context: joinCtx, observed: make(chan struct{})}
	joinDone := make(chan struct{})
	go func() {
		defer close(joinDone)
		n, err := a.ingest(joined, key, func() (int, error) { t.Error("duplicated work"); return 0, nil })
		if n != 0 || !errors.Is(err, context.Canceled) {
			t.Errorf("join cancellation %d %v", n, err)
		}
	}()
	<-joined.observed
	cancelJoin()
	<-joinDone
	select {
	case <-ownerDone:
		t.Fatal("join canceled owner")
	default:
	}
	close(release)
	<-ownerDone
}

func TestRSSExplicitAdmissionCannotJoinBackgroundZero(t *testing.T) {
	a := newRSSEnrollmentAdmission()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	background := rssEnrollmentKey{feed: "https://background-join.invalid/rss"}
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		_, _ = a.ingest(ctx, background, func() (int, error) { close(started); <-release; return 0, nil })
	}()
	<-started
	explicit := background
	explicit.explicit = true
	n, err := a.ingest(ctx, explicit, func() (int, error) { return 3, nil })
	close(release)
	<-done
	if n != 3 || err != nil {
		t.Fatalf("explicit joined background result: %d %v", n, err)
	}
}

func TestRSSEnrollmentConfigurationCapsWorkerCount(t *testing.T) {
	for _, test := range []struct {
		raw  string
		want int
	}{{"", 16}, {"4", 4}, {"999999", 16}, {"0", 16}, {"-1", 16}} {
		e := NewEnroller(nil, nil, nil, nil, nil, map[string]string{"THIN_APPVIEW_MAX_RSS_ENROLL_CONCURRENCY": test.raw})
		if e.RSSConcurrency != test.want {
			t.Errorf("%q: %d, want %d", test.raw, e.RSSConcurrency, test.want)
		}
	}
}

func TestRSSEnrollmentAttemptsAllFeedsOnDatabaseFailures(t *testing.T) {
	db, err := sql.Open("pgx", "postgres://unused.invalid/unused")
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	repo := &rssEnrollmentRepo{}
	feeds := []string{"https://db-failure-a.invalid/rss", "https://db-failure-b.invalid/rss", "https://db-failure-c.invalid/rss"}
	for _, feed := range feeds {
		repo.records = append(repo.records, gatewaycore.RepoRecord{Value: map[string]json.RawMessage{"feedUrl": json.RawMessage(fmt.Sprintf("%q", feed))}})
	}
	var calls atomic.Int32
	getter := getterFunc(func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error) {
		calls.Add(1)
		return 200, nil, enrollmentRSSBody, nil
	})
	e := Enroller{Repo: repo, RSSConcurrency: 1, RSS: &thinappviewcore.RSSIngestion{DB: db, HTTP: getter}}
	n, err := e.Enroll(context.Background(), gatewaycore.AuthContext{DID: "viewer"}, nil, feeds, true)
	if n != 0 || err == nil || calls.Load() != 0 || strings.Count(err.Error(), "sql: database is closed") != 3 {
		t.Fatalf("count=%d error=%v calls=%d", n, err, calls.Load())
	}
}
