package store

import (
	"context"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestInboxBatchBoundsPayloadsAndParameters(t *testing.T) {
	events := make([]ingest.InboxEvent, inboxInsertMaxRows+1)
	if got := inboxBatchEnd(events, 0); got != inboxInsertMaxRows {
		t.Fatalf("row bound = %d", got)
	}
	events = []ingest.InboxEvent{{Payload: make([]byte, inboxInsertMaxPayloadBytes)}, {Payload: []byte("{}")}}
	if got := inboxBatchEnd(events, 0); got != 1 {
		t.Fatalf("payload bound = %d", got)
	}
	if got := inboxBatchEnd(events, 1); got != 2 {
		t.Fatalf("following payload batch = %d", got)
	}
	events[0].Payload = make([]byte, inboxInsertMaxPayloadBytes+1)
	if got := inboxBatchEnd(events, 0); got != 1 {
		t.Fatalf("oversize event must make progress alone, got %d", got)
	}
}

func TestStageBatchInsertsMultipleRowsWithOneAtomicCheckpoint(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	now := time.Now().UTC()
	events := []ingest.InboxEvent{
		{Seq: 10, Time: now, Kind: "commit", RepoDID: "did:plc:one", Payload: []byte(`{}`)},
		{Seq: 11, Time: now, Kind: "identity", RepoDID: "did:plc:two", Payload: []byte(`{"identity":{}}`)},
	}
	var args []driver.Value
	for _, event := range events {
		args = append(args, "dev", "west-v1", int64(event.Seq), "jetstream.us-west.bsky.network",
			"jetstream_v2_seq", event.Kind, event.RepoDID, nil, nil, nil, nil, nil, string(event.Payload), now)
	}
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec(`INSERT INTO appview_ingestion_inbox.*\$28::timestamptz`).WithArgs(args...).WillReturnResult(sqlmock.NewResult(0, 2))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	if err := store.StageBatch(context.Background(), Lease{}, events, 11, now, ReplayProgress{}); err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageBatchLaterChunkFailureRollsBackEarlierRowsAndCheckpoint(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	events := make([]ingest.InboxEvent, inboxInsertMaxRows+1)
	for index := range events {
		events[index] = ingest.InboxEvent{Seq: uint64(index + 1), Time: time.Now(), Payload: []byte(`{}`)}
	}
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec("INSERT INTO appview_ingestion_inbox").WillReturnResult(sqlmock.NewResult(0, inboxInsertMaxRows))
	mock.ExpectExec("INSERT INTO appview_ingestion_inbox").WillReturnError(errors.New("disk full"))
	mock.ExpectRollback()
	if err := store.StageBatch(context.Background(), Lease{}, events, uint64(len(events)), time.Now(), ReplayProgress{}); err == nil {
		t.Fatal("expected later chunk failure")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresApplicationName(t *testing.T) {
	for _, test := range []struct{ input, want string }{
		{"", "jetstream-ingest"}, {"  ", "jetstream-ingest"}, {"Jetstream V2 Ingest", "Jetstream-V2-Ingest"},
		{"ingest\nworker", "ingest-worker"}, {strings.Repeat("x", 100), strings.Repeat("x", 63)},
	} {
		if got := postgresApplicationName(test.input); got != test.want {
			t.Errorf("application name %q = %q, want %q", test.input, got, test.want)
		}
	}
}
