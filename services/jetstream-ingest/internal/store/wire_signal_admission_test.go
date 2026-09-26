package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func wireSignal(collection, operation, subject string) ingest.InboxEvent {
	return ingest.InboxEvent{Collection: &collection, Operation: &operation, Kind: "commit", Payload: []byte(`{"did":"did:plc:actor","seq":9223372036854775807,"time_us":1720000000000000,"kind":"commit","commit":{"collection":"` + collection + `","operation":"` + operation + `","rkey":"r","rev":"rev","cid":"cid","record":{"$type":"` + collection + `","subject":` + subject + `,"createdAt":"2026-01-01T00:00:00Z","unused":"large extra data"}}}`)}
}

func TestCompactWirePayloadPreservesEnvelopeAndSubjectShapes(t *testing.T) {
	for _, collection := range []string{"app.bsky.feed.like", "app.bsky.feed.repost", "app.bsky.graph.follow"} {
		for _, subject := range []string{`{"uri":"at://post","cid":"subject-cid"}`, `"did:plc:followee"`, `null`, `3`, `[]`, `{"uri":false}`} {
			event := wireSignal(collection, "update", subject)
			var before, after map[string]json.RawMessage
			json.Unmarshal(event.Payload, &before)
			compact := compactWirePayload(event)
			json.Unmarshal(compact, &after)
			var beforeCommit, afterCommit, record map[string]json.RawMessage
			json.Unmarshal(before["commit"], &beforeCommit)
			json.Unmarshal(after["commit"], &afterCommit)
			json.Unmarshal(afterCommit["record"], &record)
			if string(record["subject"]) != subject || record["unused"] != nil || len(record) != 3 {
				t.Fatalf("subject %s compacted incorrectly: %s", subject, compact)
			}
			delete(beforeCommit, "record")
			delete(afterCommit, "record")
			if !reflect.DeepEqual(beforeCommit, afterCommit) {
				t.Fatalf("commit identity changed: %s", compact)
			}
			delete(before, "commit")
			delete(after, "commit")
			if !reflect.DeepEqual(before, after) {
				t.Fatalf("envelope identity changed: %s", compact)
			}
			if !strings.Contains(string(event.Payload), "large extra data") {
				t.Fatal("mutated caller payload")
			}
		}
	}
}

func TestCompactWirePayloadDeleteAndUnchangedCollections(t *testing.T) {
	event := wireSignal("app.bsky.feed.like", "delete", `{"uri":"at://post"}`)
	compact := compactWirePayload(event)
	if strings.Contains(string(compact), `"record":`) || !strings.Contains(string(compact), `"rev":"rev"`) {
		t.Fatalf("delete payload = %s", compact)
	}
	for _, collection := range []string{"site.standard.document", "site.standard.publication", "app.bsky.feed.post", "site.standard.graph.recommend"} {
		event := wireSignal(collection, "create", `{"uri":"at://post"}`)
		if string(compactWirePayload(event)) != string(event.Payload) {
			t.Fatalf("changed %s payload", collection)
		}
	}
}

func TestCompactionPreservesMalformedBehavior(t *testing.T) {
	event := wireSignal("app.bsky.graph.follow", "create", `"did:plc:followee"`)
	event.Payload = []byte(`{"commit":{"record":{"subject":"did:plc:followee","discarded":{"key\u0000":1,"key\ufffd":2}}}}`)
	if !strings.Contains(string(compactWirePayload(event)), wirePayloadNormalizationFailureCode) {
		t.Fatal("discarded invalid field concealed normalization failure")
	}
	for _, payload := range []string{`{"commit":{"record":null}}`, `{"commit":{"record":"bad"}}`, `{"commit":{"record":[]}}`} {
		event.Payload = []byte(payload)
		if string(compactWirePayload(event)) != payload {
			t.Fatalf("malformed record repaired: %s", payload)
		}
	}
}

func TestWireAdmissionDeduplicatesBoundedKeysAndKeepsOrderedLifecycle(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	events := make([]ingest.InboxEvent, 0)
	keys := make([]string, wireSubjectLookupBatchSize)
	for i := range keys {
		keys[i] = fmt.Sprintf("at://post/%d", i)
		subject, _ := json.Marshal(keys[i])
		events = append(events, wireSignal("app.bsky.feed.like", "create", `{"uri":`+string(subject)+`}`))
	}
	events = append(events, events[0], wireSignal("app.bsky.feed.repost", "update", `{"uri":"at://last"}`))
	follow := wireSignal("app.bsky.graph.follow", "create", `"did:plc:newly-active"`)
	deletion := wireSignal("app.bsky.feed.like", "delete", `null`)
	account := ingest.InboxEvent{Kind: "account", Payload: []byte(`{"account":{"active":false}}`)}
	events = append(events, follow, deletion, account, wireSignal("app.bsky.feed.like", "create", `"at://last"`))
	firstKeys, _ := json.Marshal(keys)
	mock.ExpectQuery("SELECT requested.ordinality").WithArgs(string(firstKeys)).WillReturnRows(sqlmock.NewRows([]string{"ordinality"}).AddRow(1))
	mock.ExpectQuery("SELECT requested.ordinality").WithArgs(`["at://last"]`).WillReturnRows(sqlmock.NewRows([]string{"ordinality"}).AddRow(1))
	got, err := filterWireSignals(context.Background(), tx, events)
	if err != nil {
		t.Fatal(err)
	}
	want := []ingest.InboxEvent{events[0], events[wireSubjectLookupBatchSize], events[wireSubjectLookupBatchSize+1], follow, deletion, account}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ordered admission mismatch: got %d events want %d", len(got), len(want))
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageRetriesWholeTransactionAfterSerializationConflict(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	p := New(db, wireTestSource())
	p.ConfigureWireCompactIngest(true)
	event := wireSignal("app.bsky.feed.like", "create", `{"uri":"at://post"}`)
	event.Seq = 12
	event.Time = time.Now().UTC()
	filtered := wireSignal("app.bsky.feed.like", "create", `{"uri":"at://missing"}`)
	filtered.Seq = 13
	filtered.Time = event.Time
	for attempt := 0; attempt < 2; attempt++ {
		mock.ExpectBegin()
		mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
		mock.ExpectQuery("SELECT requested.ordinality").WillReturnRows(sqlmock.NewRows([]string{"ordinality"}).AddRow(1))
		mock.ExpectExec("INSERT INTO wire_ingestion_inbox").WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectExec("UPDATE wire_ingestion_admission").WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectExec("INSERT INTO wire_ingestion_recovery_anchors").WillReturnResult(sqlmock.NewResult(0, 1))
		if attempt == 0 {
			mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnError(&pgconn.PgError{Code: "40001"})
			mock.ExpectRollback()
		} else {
			mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectCommit()
		}
	}
	if err := p.StageBatch(context.Background(), Lease{}, []ingest.InboxEvent{event, filtered}, 13, event.Time, ReplayProgress{}); err != nil {
		t.Fatal(err)
	}
	snapshot := p.wirePreprocessing.snapshot()
	want := wirePreprocessingSnapshot{
		inputBatches: 1, inputEvents: 2,
		originalBytes:    uint64(len(event.Payload) + len(filtered.Payload)),
		compactBytes:     uint64(len(compactWirePayload(event)) + len(compactWirePayload(filtered))),
		committedBatches: 1, acceptedEvents: 1, insertedEvents: 1,
		acceptedBytes: uint64(len(compactWirePayload(event))), filteredPassiveEvents: 1,
		lookupSubjects: 2, lookupBytes: uint64(len(`["at://post","at://missing"]`)),
	}
	if snapshot != want {
		t.Fatalf("retried batch metrics = %+v, want %+v", snapshot, want)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestSerializationRetryIsBoundedAndCancellable(t *testing.T) {
	attempts := 0
	err := retryStageSerialization(context.Background(), func() error { attempts++; return &pgconn.PgError{Code: "40001"} })
	if err == nil || attempts != 5 {
		t.Fatalf("retry attempts = %d, err = %v", attempts, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	attempts = 0
	err = retryStageSerialization(ctx, func() error { attempts++; return &pgconn.PgError{Code: "40001"} })
	if !errors.Is(err, context.Canceled) || attempts != 1 {
		t.Fatalf("cancelled retry attempts = %d, err = %v", attempts, err)
	}
	attempts = 0
	err = retryStageSerialization(context.Background(), func() error { attempts++; return &pgconn.PgError{Code: "23505"} })
	if err == nil || attempts != 1 {
		t.Fatal("non-serialization error was retried")
	}
}

func TestSubjectLookupBoundsPayloadCopies(t *testing.T) {
	subjects := []json.RawMessage{make([]byte, inboxInsertMaxPayloadBytes), []byte(`"next"`)}
	if got := wireSubjectBatchEnd(subjects, 0); got != 1 {
		t.Fatalf("large subject combined with next: %d", got)
	}
	if got := wireSubjectBatchEnd(subjects, 1); got != 2 {
		t.Fatalf("next subject failed to advance: %d", got)
	}
	subjects[0] = make([]byte, inboxInsertMaxPayloadBytes+1)
	if got := wireSubjectBatchEnd(subjects, 0); got != 1 {
		t.Fatalf("oversize subject failed to advance alone: %d", got)
	}
}
