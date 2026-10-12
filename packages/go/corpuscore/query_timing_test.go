package corpuscore

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"
)

func TestQueryObservationPoolCancellationAndRelease(t *testing.T) {
	state := &batchSQLConnector{now: time.Now(), fresh: true}
	db := sql.OpenDB(state)
	defer db.Close()
	db.SetMaxOpenConns(1)
	held, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	phases := []string{}
	ctx, cancel := context.WithCancel(WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases = append(phases, phase) }))
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, _, err := QueryRows(ctx, db, `SELECT has_current_snapshot,oldest_successful_at FROM wire_serving.label_health`)
		result <- err
	}()
	deadline := time.Now().Add(time.Second)
	for db.Stats().WaitCount == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if db.Stats().WaitCount == 0 {
		t.Fatal("query did not wait for the occupied pool")
	}
	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if len(state.queries) != 0 || len(phases) != 1 || phases[0] != "db-acquisition" {
		t.Fatal(state.queries, phases)
	}
	held.Close()
	phases = nil
	ctx = WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases = append(phases, phase) })
	rows, closeRows, err := QueryRows(ctx, db, `SELECT has_current_snapshot,oldest_successful_at FROM wire_serving.label_health`)
	if err != nil {
		t.Fatal(err)
	}
	if !rows.Next() {
		t.Fatal("missing query result")
	}
	closeRows()
	closeRows()
	if db.Stats().InUse != 0 || len(phases) != 2 || phases[0] != "db-acquisition" || phases[1] != "db-query" {
		t.Fatal(db.Stats(), phases)
	}
	phases = nil
	if _, _, err = QueryRows(ctx, db, "unexpected SQL"); err == nil {
		t.Fatal("expected query error")
	}
	if db.Stats().InUse != 0 || len(phases) != 2 || phases[1] != "db-query" {
		t.Fatal("query error leaked connection", db.Stats(), phases)
	}
}
