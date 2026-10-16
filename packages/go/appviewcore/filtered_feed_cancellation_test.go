package appviewcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"testing"
	"time"
)

type filteredFeedFixtureRows struct {
	values  [][]driver.Value
	columns int
}

func (r *filteredFeedFixtureRows) Columns() []string { return make([]string, r.columns) }
func (*filteredFeedFixtureRows) Close() error        { return nil }
func (r *filteredFeedFixtureRows) Next(values []driver.Value) error {
	if len(r.values) == 0 {
		return io.EOF
	}
	copy(values, r.values[0])
	r.values = r.values[1:]
	return nil
}

func TestFilteredFeedRefillRetainsCallerCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	deadline, _ := ctx.Deadline()
	calls := 0
	at := time.Now()
	db := sql.OpenDB(batchDeadlineConnector{query: func(work context.Context) (driver.Rows, error) {
		calls++
		if got, ok := work.Deadline(); !ok || !got.Equal(deadline) {
			t.Fatalf("refill changed deadline: %v", got)
		}
		switch calls {
		case 1:
			return &filteredFeedFixtureRows{columns: 4, values: [][]driver.Value{{at, "publication", "author", "site"}}}, nil
		case 2:
			values := make([][]driver.Value, 16)
			for i := range values {
				values[i] = []driver.Value{int64(0), "uri", at, "site"}
			}
			return &filteredFeedFixtureRows{columns: 4, values: values}, nil
		case 3:
			return &filteredFeedFixtureRows{columns: 3, values: [][]driver.Value{{int64(15), int64(0), true}}}, nil
		default:
			cancel()
			return nil, work.Err()
		}
	}})
	defer db.Close()
	page, err := (FeedStore{DB: db}).Feed(ctx, "viewer", "subscribed", "", "unread", "", 1, at)
	if !errors.Is(err, context.Canceled) || page != nil || calls != 4 {
		t.Fatalf("refill cancellation page=%#v err=%v calls=%d", page, err, calls)
	}
}
