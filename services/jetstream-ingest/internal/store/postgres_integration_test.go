package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestPostgresStageBatchIntegration(t *testing.T) {
	databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	generation := fmt.Sprintf("integration-%d", time.Now().UnixNano())
	source := ingest.SourceIdentity{
		Environment: "dev", Host: "jetstream.us-west.bsky.network",
		StreamNSID: "network.bsky.jetstream.subscribeEvents", FilterFingerprint: "integration-filter",
		CursorKind: "jetstream_v2_seq", Generation: generation,
	}
	postgres := New(db, source)
	lease, err := postgres.AcquireLease(ctx, "integration-"+generation, "integration-owner", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_inbox WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_jetstream_checkpoints WHERE environment = $1 AND source_generation = $2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_leases WHERE environment = $1 AND lease_name = $2", source.Environment, lease.Name)
	})
	now := time.Now().UTC()
	event := ingest.InboxEvent{
		Seq: 77, Time: now, Kind: "commit", RepoDID: "did:plc:integration",
		Payload: []byte(`{"did":"did:plc:integration","cursor":77,"time_us":1,"kind":"commit","commit":{"operation":"delete","collection":"site.standard.entry","rkey":"one","rev":"one"}}`),
	}
	if err := postgres.StageBatch(ctx, lease, []ingest.InboxEvent{event}, 77, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	var kind string
	var cursor int64
	err = db.QueryRowContext(ctx, `
		SELECT payload->>'kind', payload->>'cursor'
		FROM appview_ingestion_inbox
		WHERE environment = $1 AND source_generation = $2 AND seq = 77`, source.Environment, generation).
		Scan(&kind, &cursor)
	if err != nil {
		t.Fatal(err)
	}
	if kind != "commit" || cursor != 77 {
		t.Fatalf("stored payload kind=%q cursor=%d", kind, cursor)
	}
	checkpoint, err := postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || checkpoint.LastStagedSeq != 77 {
		t.Fatalf("checkpoint = %#v", checkpoint)
	}
}
