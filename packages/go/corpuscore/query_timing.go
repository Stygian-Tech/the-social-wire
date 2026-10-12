package corpuscore

import (
	"context"
	"database/sql"
	"sync"
	"time"
)

type queryObserverKey struct{}

// WithQueryObserver reports only fixed phase names and durations; SQL, arguments
// and viewer identity never enter the observer.
func WithQueryObserver(ctx context.Context, observer func(string, time.Duration)) context.Context {
	return context.WithValue(ctx, queryObserverKey{}, observer)
}

// QueryRows preserves ordinary pool behavior when observation is absent. With an
// observer, acquisition is measured separately and the owned connection remains
// reserved until rows are drained or closed. Call closeRows on every success.
func QueryRows(ctx context.Context, db *sql.DB, statement string, args ...any) (*sql.Rows, func(), error) {
	observer, _ := ctx.Value(queryObserverKey{}).(func(string, time.Duration))
	if observer == nil {
		rows, err := db.QueryContext(ctx, statement, args...)
		if err != nil {
			return nil, nil, err
		}
		return rows, func() { rows.Close() }, nil
	}
	started := time.Now()
	conn, err := db.Conn(ctx)
	observer("db-acquisition", time.Since(started))
	if err != nil {
		return nil, nil, err
	}
	started = time.Now()
	rows, err := conn.QueryContext(ctx, statement, args...)
	if err != nil {
		elapsed := time.Since(started)
		conn.Close()
		observer("db-query", elapsed)
		return nil, nil, err
	}
	var once sync.Once
	closeRows := func() {
		once.Do(func() {
			rows.Close()
			elapsed := time.Since(started)
			conn.Close()
			observer("db-query", elapsed)
		})
	}
	return rows, closeRows, nil
}
