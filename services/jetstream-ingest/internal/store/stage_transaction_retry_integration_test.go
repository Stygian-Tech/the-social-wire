package store

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestStageBatchRetriesConcurrentAdmissionSnapshotIntegration(t *testing.T) {
	databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	id, err := newIncidentID()
	if err != nil {
		t.Fatal(err)
	}
	application := "stage-retry-" + id
	parsed, err := url.Parse(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	query := parsed.Query()
	query.Set("application_name", application)
	parsed.RawQuery = query.Encode()
	db, err := sql.Open("pgx", parsed.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	source := wireTestSource()
	source.Environment = application
	source.Generation = application
	p := New(db, source)
	p.ConfigureWireCompactIngest(true)
	p.ConfigureWireAdmission(1000, 1<<40)
	lease, err := p.AcquireLease(ctx, application, "test-owner", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, table := range []string{"wire_ingestion_inbox", "wire_ingestion_recovery_anchors", "appview_jetstream_checkpoints", "appview_ingestion_leases", "wire_ingestion_admission"} {
			_, _ = db.ExecContext(cleanup, "DELETE FROM "+table+" WHERE environment=$1", source.Environment)
		}
	})
	if _, err := db.ExecContext(ctx, "INSERT INTO wire_ingestion_admission(environment,retained_rows) VALUES($1,0)", source.Environment); err != nil {
		t.Fatal(err)
	}
	blocker, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback()
	if _, err := blocker.ExecContext(ctx, "UPDATE wire_ingestion_admission SET retained_rows=retained_rows+1 WHERE environment=$1", source.Environment); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	event := ingest.InboxEvent{Seq: 42, Time: now, Kind: "account", RepoDID: "did:plc:test", Payload: []byte(`{"account":{"active":true}}`)}
	finished := make(chan error, 1)
	go func() {
		finished <- p.StageBatch(ctx, lease, []ingest.InboxEvent{event}, 42, now, ReplayProgress{State: "live", BytesDownloaded: 1234})
	}()
	// Wait for StageBatch to establish its repeatable-read snapshot and block
	// behind the other lane's admission update. Committing that update forces
	// the real PostgreSQL 40001 that must be retried without reopening Jetstream.
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		var waiting bool
		if err := db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock' AND query LIKE '%SELECT retained_rows, pg_database_size%')`, application).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-finished:
			t.Fatalf("stage finished before admission contention: %v", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-ticker.C:
		}
	}
	if err := blocker.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	var retained, rows, bytes, seq int64
	if err := db.QueryRowContext(ctx, `SELECT admission.retained_rows,(SELECT COUNT(*) FROM wire_ingestion_inbox WHERE environment=$1),checkpoint.replay_bytes_downloaded,checkpoint.last_staged_seq FROM wire_ingestion_admission admission JOIN appview_jetstream_checkpoints checkpoint USING(environment) WHERE admission.environment=$1`, source.Environment).Scan(&retained, &rows, &bytes, &seq); err != nil {
		t.Fatal(err)
	}
	if retained != 2 || rows != 1 || bytes != 1234 || seq != 42 {
		t.Fatalf("conflict changed atomic admission/checkpoint: retained=%d rows=%d bytes=%d seq=%d", retained, rows, bytes, seq)
	}
	metrics := p.wirePreprocessing.snapshot()
	if metrics.inputBatches != 1 || metrics.committedBatches != 1 || metrics.insertedEvents != 1 {
		t.Fatalf("conflict inflated metrics: %+v", metrics)
	}
}
