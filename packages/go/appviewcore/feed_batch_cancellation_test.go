package appviewcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"testing"
	"time"
)

type batchDeadlineConnector struct {
	query func(context.Context) (driver.Rows, error)
}

func (c batchDeadlineConnector) Connect(context.Context) (driver.Conn, error) {
	return batchDeadlineConnection{c.query}, nil
}
func (c batchDeadlineConnector) Driver() driver.Driver { return batchDeadlineDriver{} }

type batchDeadlineDriver struct{}

func (batchDeadlineDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type batchDeadlineConnection struct {
	query func(context.Context) (driver.Rows, error)
}

func (batchDeadlineConnection) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (batchDeadlineConnection) Close() error { return nil }
func (batchDeadlineConnection) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected transaction")
}
func (c batchDeadlineConnection) QueryContext(ctx context.Context, _ string, _ []driver.NamedValue) (driver.Rows, error) {
	return c.query(ctx)
}

type sparseBatchRows struct {
	remaining  int
	at         time.Time
	articleKey string
}

func (*sparseBatchRows) Columns() []string {
	return []string{"updated_at", "uri", "render", "created_at", "publication", "read", "article"}
}
func (*sparseBatchRows) Close() error { return nil }
func (r *sparseBatchRows) Next(values []driver.Value) error {
	if r.remaining == 0 {
		return io.EOF
	}
	r.remaining--
	uri := fmt.Sprintf("at://fixture/site.standard.document/%d", r.remaining)
	article := uri
	if r.articleKey != "" {
		article = r.articleKey
	}
	copy(values, []driver.Value{r.at, uri, `{"title":"Entry"}`, r.at.Add(time.Duration(r.remaining) * time.Second), "publication", true, article})
	return nil
}
func TestSparseFeedContinuationRetainsCallerDeadline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	want, _ := ctx.Deadline()
	queries := 0
	db := sql.OpenDB(batchDeadlineConnector{query: func(work context.Context) (driver.Rows, error) {
		queries++
		got, ok := work.Deadline()
		if !ok || !got.Equal(want) {
			t.Fatalf("continuation renewed deadline: %v want %v", got, want)
		}
		if queries == 1 {
			return &sparseBatchRows{remaining: 32, at: time.Now(), articleKey: "duplicate"}, nil
		}
		<-work.Done()
		return nil, work.Err()
	}})
	defer db.Close()
	page, err := (FeedStore{DB: db}).Feed(ctx, "viewer", "subscribed", "", "all", "", 1, time.Now())
	if !errors.Is(err, context.DeadlineExceeded) || page != nil || queries != 2 {
		t.Fatalf("sparse continuation cancellation: page=%#v err=%v queries=%d", page, err, queries)
	}
}
