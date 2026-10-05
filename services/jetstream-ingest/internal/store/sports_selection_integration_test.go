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

func TestSportsOnlyViewerSelectionIntakeIntegration(t *testing.T) {
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
	generation := fmt.Sprintf("integration-sports-%d", time.Now().UnixNano())
	viewer := "did:plc:" + generation
	source := ingest.SourceIdentity{Environment: "dev", Host: "jetstream.us-west.bsky.network", StreamNSID: "network.bsky.jetstream.subscribeEvents", FilterFingerprint: "sports-test", CursorKind: "jetstream_v2_seq", Generation: generation}
	store := New(db, source)
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		_, _ = db.ExecContext(cleanup, "DELETE FROM appview_ingestion_inbox WHERE source_generation=$1", generation)
		_, _ = db.ExecContext(cleanup, "DELETE FROM sports_selection_sync WHERE viewer_did=$1", viewer)
	})
	if _, err := db.ExecContext(ctx, "INSERT INTO sports_selection_sync(viewer_did,synced_at) VALUES($1,NOW())", viewer); err != nil {
		t.Fatal(err)
	}
	tracked, err := store.TrackedDIDs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, found := tracked[viewer]; !found {
		t.Fatal("Sports-only viewer omitted from lifecycle tracking")
	}
	collection := "app.thesocialwire.sports.selection"
	unrelated := "app.skyreader.feed.subscription"
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	events := []ingest.InboxEvent{}
	for index, operation := range []string{"create", "update", "delete"} {
		action := "follow"
		if index == 1 {
			action = "mute"
		}
		key := "stable-entity-key"
		events = append(events, ingest.InboxEvent{Seq: uint64(index + 1), Time: time.Now().UTC(), Kind: "commit", RepoDID: viewer, Collection: &collection, Operation: &operation, RecordKey: &key, Payload: []byte(fmt.Sprintf(`{"commit":{"record":{"$type":"app.thesocialwire.sports.selection","reference":"sports-team-fixture","action":"%s"}}}`, action))})
	}
	unknown := events[0]
	unknown.Seq = 4
	unknown.RepoDID = "did:plc:unknown-sports-fixture"
	unrelatedEvent := events[0]
	unrelatedEvent.Seq = 5
	unrelatedEvent.Collection = &unrelated
	events = append(events, unknown, unrelatedEvent)
	count, err := store.stageInboxEvents(ctx, tx, events)
	if err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("staged %d rows, want only three Sports mutations", count)
	}
	rows, err := tx.QueryContext(ctx, "SELECT operation,payload #>> '{commit,record,action}' FROM appview_ingestion_inbox WHERE source_generation=$1 ORDER BY seq", generation)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for index, expected := range []string{"create", "update", "delete"} {
		if !rows.Next() {
			t.Fatal("missing selection mutation")
		}
		var operation, action string
		if err := rows.Scan(&operation, &action); err != nil {
			t.Fatal(err)
		}
		expectedAction := "follow"
		if index == 1 {
			expectedAction = "mute"
		}
		if operation != expected || action != expectedAction {
			t.Fatalf("mutation %d = %s/%s", index, operation, action)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
}
