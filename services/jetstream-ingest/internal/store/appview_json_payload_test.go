package store

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestStageAppViewBatchNormalizesUnsupportedUnicode(t *testing.T) {
	for _, test := range []struct{ name, payload, want string }{
		{"NUL", `{"commit":{"cid":"cid-original","record":{"text":"before\u0000after","literal":"\\u0000","counter":9223372036854775807}}}`, `{"commit":{"cid":"cid-original","record":{"counter":9223372036854775807,"literal":"\\u0000","text":"before�after"}}}`},
		{"surrogate", `{"commit":{"record":{"text":"before\ud800after","emoji":"\ud83d\ude00"}}}`, `{"commit":{"record":{"emoji":"😀","text":"before�after"}}}`},
		{"key", `{"commit":{"record":{"before\u0000after":true}}}`, `{"commit":{"record":{"before�after":true}}}`},
		{"ordinary unchanged", `{ "commit": {"record":{"text":"ordinary"}} }`, `{ "commit": {"record":{"text":"ordinary"}} }`},
	} {
		t.Run(test.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			store := New(db, testSource())
			now := time.Unix(1700000000, 0).UTC()
			cid := "cid-original"
			event := ingest.InboxEvent{Seq: 7, Time: now, Kind: "commit", RepoDID: "did:plc:test", RecordCID: &cid, Payload: []byte(test.payload)}
			original := bytes.Clone(event.Payload)
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
			mock.ExpectExec("INSERT INTO appview_ingestion_inbox").WithArgs(
				"dev", "west-v1", int64(7), "jetstream.us-west.bsky.network", "jetstream_v2_seq", "commit", "did:plc:test", nil, nil, nil, nil, cid, test.want, now,
			).WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectCommit()
			if err := store.StageBatch(context.Background(), Lease{}, []ingest.InboxEvent{event}, event.Seq, now, ReplayProgress{}); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(event.Payload, original) {
				t.Fatalf("caller payload changed: %s", event.Payload)
			}
			if !json.Valid(event.Payload) {
				t.Fatal("original envelope corrupted")
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestStageAppViewBatchNormalizationFailurePreservesCheckpoint(t *testing.T) {
	for _, payload := range []string{`{"record":`, `{"record":{"same\u0000key":1,"same\ufffdkey":2}}`} {
		t.Run(payload, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			store := New(db, testSource())
			now := time.Unix(1700000000, 0).UTC()
			events := []ingest.InboxEvent{{Seq: 7, Time: now, Payload: []byte(`{}`)}, {Seq: 8, Time: now, Payload: []byte(payload)}}
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
			mock.ExpectRollback()
			err = store.StageBatch(context.Background(), Lease{}, events, 8, now, ReplayProgress{})
			if err == nil || !strings.Contains(err.Error(), "normalize AppView inbox payload at seq 8") {
				t.Fatalf("expected explicit normalization error, got %v", err)
			}
			if string(events[1].Payload) != payload {
				t.Fatal("caller payload changed")
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
