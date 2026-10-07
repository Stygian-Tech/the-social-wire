package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestWorkerCommandReplayAndLeaseFence(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, _ := NewPostgresStore(tx, "dev")
	at := time.Now().UTC().Truncate(time.Microsecond)
	// Fixtures remain in a rolled-back transaction, including clearing unrelated queued fixtures.
	if _, err = tx.Exec(ctx, `DELETE FROM operations_commands WHERE environment='dev'`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_stream_state(environment,source,version) VALUES('dev','jetstream',123) ON CONFLICT(environment,source) DO UPDATE SET version=123`); err != nil {
		t.Fatal(err)
	}
	key, _ := randomUUID()
	queued, err := store.CreateCommand(ctx, "reconnect_jetstream", "did:plc:fixture", nil, 123, key, nil, at)
	if err != nil || queued.Version != 0 || queued.Status != "queued" {
		t.Fatal(queued, err)
	}
	if _, err = store.CreateCommand(ctx, "reconnect_jetstream", "did:plc:fixture", nil, 122, key+"stale", nil, at); !errors.Is(err, ErrVersionConflict) {
		t.Fatal("stale stream version accepted", err)
	}
	claimed, err := store.ClaimNextCommand(ctx, "reconnect_jetstream", "worker-a", at)
	if err != nil || claimed == nil || claimed.ID != queued.ID || claimed.Version != 1 {
		t.Fatal(claimed, err)
	}
	if second, err := store.ClaimNextCommand(ctx, "reconnect_jetstream", "worker-b", at.Add(time.Second)); err != nil || second != nil {
		t.Fatal("active lease stolen", second, err)
	}
	if _, err = store.CompleteCommand(ctx, queued.ID, "completed", nil, "worker-b", 1, nil, nil, at); !errors.Is(err, ErrLeaseConflict) {
		t.Fatal("wrong owner completed command", err)
	}
	// Failed savepoint mutations must not poison the containing PostgreSQL transaction.
	reclaimed, err := store.ClaimNextCommand(ctx, "reconnect_jetstream", "worker-b", at.Add(301*time.Second))
	if err != nil || reclaimed == nil || reclaimed.Version != 2 {
		t.Fatal(reclaimed, err)
	}
	if _, err = store.CompleteCommand(ctx, queued.ID, "completed", nil, "worker-a", 1, nil, nil, at.Add(301*time.Second)); !errors.Is(err, ErrLeaseConflict) {
		t.Fatal("superseded lease completed command", err)
	}
	completed, err := store.CompleteCommand(ctx, queued.ID, "completed", nil, "worker-b", 2, nil, nil, at.Add(302*time.Second))
	if err != nil || completed.Version != 3 || completed.LeaseExpiresAt != nil || completed.CompletedAt == nil {
		t.Fatal(completed, err)
	}
	replay, err := store.CreateCommand(ctx, "reconnect_jetstream", "did:plc:fixture", nil, 123, key, nil, at)
	if err != nil || replay.Status != "queued" || replay.Version != 0 || replay.ID != queued.ID {
		t.Fatal("original response replay changed", replay, err)
	}
	page, err := store.ListCommands(ctx, 1, nil)
	if err != nil || len(page.Items) != 1 || page.Items[0].Status != "completed" || page.TotalCount != 1 {
		t.Fatal(page, err)
	}
	var audits int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM operations_audit_events WHERE environment='dev' AND target_id=$1`, queued.ID).Scan(&audits); err != nil || audits != 3 {
		t.Fatal(audits, err)
	}
}
