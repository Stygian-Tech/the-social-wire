package reader

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type feedDeadlineConnector struct {
	query func(context.Context) (driver.Rows, error)
}

func (c feedDeadlineConnector) Connect(context.Context) (driver.Conn, error) {
	return feedDeadlineConn{c.query}, nil
}
func (c feedDeadlineConnector) Driver() driver.Driver { return feedDeadlineDriver{} }

type feedDeadlineDriver struct{}

func (feedDeadlineDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type feedDeadlineConn struct {
	query func(context.Context) (driver.Rows, error)
}

func (feedDeadlineConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (feedDeadlineConn) Close() error              { return nil }
func (feedDeadlineConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected transaction") }
func (c feedDeadlineConn) QueryContext(ctx context.Context, _ string, _ []driver.NamedValue) (driver.Rows, error) {
	return c.query(ctx)
}

type emptyFeedRows struct{}

func (emptyFeedRows) Columns() []string {
	return []string{"updated_at", "uri", "render", "created_at", "publication", "read"}
}
func (emptyFeedRows) Close() error              { return nil }
func (emptyFeedRows) Next([]driver.Value) error { return io.EOF }
func deadlineRequest(ctx context.Context, kind string) *http.Request {
	r := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.appview.getFeed?kind="+kind+"&id=fixture", nil)
	r.Header.Set("X-Request-ID", "deadline-fixture")
	return r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "viewer"}))
}
func assertFeedCancellation(t *testing.T, w *httptest.ResponseRecorder) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if w.Code != 504 || body["error"] != "request_cancelled" || body["retryable"] != true || body["requestId"] != "deadline-fixture" {
		t.Fatalf("cancellation response: %d %v", w.Code, body)
	}
}
func TestFeedPoolWaitUsesTwoSecondBudget(t *testing.T) {
	t.Parallel()
	reachedQuery := false
	db := sql.OpenDB(feedDeadlineConnector{query: func(context.Context) (driver.Rows, error) {
		reachedQuery = true
		return nil, errors.New("pool wait must not reach query")
	}})
	defer db.Close()
	db.SetMaxOpenConns(1)
	held, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	w := httptest.NewRecorder()
	started := time.Now()
	Routes{DB: db}.feed(w, deadlineRequest(context.Background(), "subscribed"))
	elapsed := time.Since(started)
	assertFeedCancellation(t, w)
	if reachedQuery || db.Stats().WaitCount != 1 || elapsed < 1900*time.Millisecond || elapsed > 3*time.Second {
		t.Fatalf("pool wait query=%v stats=%+v elapsed=%v", reachedQuery, db.Stats(), elapsed)
	}
}
func TestListFeedUsesTwoSecondBudget(t *testing.T) {
	t.Parallel()
	routes := Routes{ListFeed: func(ctx context.Context, _ gatewaycore.AuthContext, _, _, _ string, _ int, _ time.Time) (*appviewcore.FeedPage, error) {
		deadline, ok := ctx.Deadline()
		remaining := time.Until(deadline)
		if !ok || remaining > 2*time.Second || remaining < 1900*time.Millisecond {
			t.Fatalf("list feed budget %v present=%v", remaining, ok)
		}
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	w := httptest.NewRecorder()
	routes.feed(w, deadlineRequest(context.Background(), "list"))
	assertFeedCancellation(t, w)
}
func TestFeedRepairAndRetryPreserveEarlierCallerDeadline(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	deadline, _ := ctx.Deadline()
	var first context.Context
	queries, repairs := 0, 0
	db := sql.OpenDB(feedDeadlineConnector{query: func(work context.Context) (driver.Rows, error) {
		queries++
		got, ok := work.Deadline()
		if !ok || !got.Equal(deadline) {
			t.Fatalf("query deadline changed: %v want %v", got, deadline)
		}
		if queries == 1 {
			first = work
			return emptyFeedRows{}, nil
		}
		if work != first {
			t.Fatal("retry reset feed context")
		}
		<-work.Done()
		return nil, work.Err()
	}})
	defer db.Close()
	routes := Routes{DB: db, RepairFeed: func(work context.Context, _ string) bool {
		repairs++
		if work != first {
			t.Fatal("repair reset feed context")
		}
		return true
	}}
	w := httptest.NewRecorder()
	routes.feed(w, deadlineRequest(ctx, "subscribed"))
	assertFeedCancellation(t, w)
	if queries != 2 || repairs != 1 {
		t.Fatalf("queries=%d repairs=%d", queries, repairs)
	}
}
