package store

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestPostgresStageAppViewBatchNormalizesUnsupportedUnicode(t *testing.T) {
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
	t.Cleanup(func() { _ = db.Close() })
	generation := fmt.Sprintf("integration-appview-unicode-%d", time.Now().UnixNano())
	source := testSource()
	source.Generation = generation
	postgres := New(db, source)
	lease, err := postgres.AcquireLease(ctx, generation, "integration-owner", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	author := "did:plc:" + generation
	publication := "at://" + author + "/site.standard.publication/test"
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_jetstream_checkpoints WHERE environment=$1 AND source_generation=$2", source.Environment, generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_leases WHERE environment=$1 AND lease_name=$2", source.Environment, lease.Name)
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_publication_scopes WHERE viewer_did=$1", author)
	})
	if _, err := db.ExecContext(ctx, "INSERT INTO appview_publication_scopes (viewer_did,publication_id,author_did) VALUES ($1,$2,$1)", author, publication); err != nil {
		t.Fatal(err)
	}
	// Demonstrate the exact JSONB rejection that previously rolled back each replay.
	poison := []byte(`{"commit":{"cid":"cid-original","record":{"text":"before\u0000after","literal":"\\u0000","emoji":"\ud83d\ude00","invalid":"\ud800","counter":9223372036854775807}}}`)
	var raw string
	if err := db.QueryRowContext(ctx, "SELECT $1::jsonb", string(poison)).Scan(&raw); err == nil {
		t.Fatal("PostgreSQL unexpectedly accepted unnormalized U+0000")
	}
	collection, cid := "site.standard.document", "cid-original"
	now := time.Now().UTC()
	events := []ingest.InboxEvent{
		{Seq: 177, Time: now, Kind: "commit", RepoDID: author, Collection: &collection, RecordCID: &cid, Payload: poison},
		{Seq: 178, Time: now, Kind: "commit", RepoDID: author, Collection: &collection, Payload: []byte(`{"commit":{"record":{"text":"following event"}}}`)},
	}
	original := bytes.Clone(poison)
	if err := postgres.StageBatch(ctx, lease, events, 178, now, ReplayProgress{State: "live", LastProgressAt: now}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(events[0].Payload, original) {
		t.Fatal("caller payload changed")
	}
	var text, literal, emoji, invalid, counter, storedCID, envelopeCID string
	if err := db.QueryRowContext(ctx, `SELECT payload #>> '{commit,record,text}', payload #>> '{commit,record,literal}', payload #>> '{commit,record,emoji}', payload #>> '{commit,record,invalid}', payload #>> '{commit,record,counter}', record_cid, payload #>> '{commit,cid}' FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq=177`, source.Environment, generation).Scan(&text, &literal, &emoji, &invalid, &counter, &storedCID, &envelopeCID); err != nil {
		t.Fatal(err)
	}
	if text != "before�after" || literal != `\u0000` || emoji != "😀" || invalid != "�" || counter != "9223372036854775807" || storedCID != cid || envelopeCID != cid {
		t.Fatalf("stored envelope changed unexpectedly: text=%q literal=%q emoji=%q invalid=%q counter=%q cid=%q envelopeCID=%q", text, literal, emoji, invalid, counter, storedCID, envelopeCID)
	}
	checkpoint, err := postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || !cursorEquals(checkpoint.LastStagedSeq, 178) {
		t.Fatalf("checkpoint did not advance past poison: %#v", checkpoint)
	}
	// A later malformed envelope must not advance the durable cursor or save
	// an invented replacement record, even when earlier events in the batch are valid.
	events[0].Seq, events[1].Seq = 179, 180
	events[1].Payload = []byte(`{"record":{"same\u0000key":1,"same\ufffdkey":2}}`)
	if err := postgres.StageBatch(ctx, lease, events, 180, now, ReplayProgress{}); err == nil {
		t.Fatal("expected normalization collision failure")
	}
	checkpoint, err = postgres.LoadCheckpoint(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2", source.Environment, generation).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if checkpoint == nil || !cursorEquals(checkpoint.LastStagedSeq, 178) || count != 2 {
		t.Fatalf("failed batch was not atomic: checkpoint=%#v rows=%d", checkpoint, count)
	}
}
