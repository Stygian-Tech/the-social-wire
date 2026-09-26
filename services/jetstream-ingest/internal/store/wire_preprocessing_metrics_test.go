package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestFailedBatchCountsInputButNotAdmission(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	p := New(db, wireTestSource())
	p.ConfigureWireCompactIngest(true)
	event := wireSignal("app.bsky.feed.like", "create", `{"uri":"at://unknown"}`)
	event.Seq = 1
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectQuery("SELECT requested.ordinality").WillReturnRows(sqlmock.NewRows([]string{"ordinality"}))
	mock.ExpectExec("INSERT INTO wire_ingestion_recovery_anchors").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit().WillReturnError(errors.New("connection lost during commit"))
	if err := p.StageBatch(context.Background(), Lease{}, []ingest.InboxEvent{event}, 1, time.Now(), ReplayProgress{}); err == nil {
		t.Fatal("commit failure was ignored")
	}
	snapshot := p.wirePreprocessing.snapshot()
	want := wirePreprocessingSnapshot{inputBatches: 1, inputEvents: 1, originalBytes: uint64(len(event.Payload)), compactBytes: uint64(len(compactWirePayload(event)))}
	if snapshot != want {
		t.Fatalf("failed batch reported admission: %+v, want %+v", snapshot, want)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPreprocessingLogMetricsAreFixedIntervalDeltas(t *testing.T) {
	var metrics wirePreprocessingMetrics
	metrics.recordInput(2, 600, 500)
	metrics.recordCommitted(wireCommittedMetrics{acceptedEvents: 1, acceptedBytes: 250, insertedEvents: 1, filteredPassiveEvents: 1, lookupSubjects: 2, lookupBytes: 50})
	previous := metrics.snapshot()
	metrics.recordInput(3, 800, 600)
	metrics.recordCommitted(wireCommittedMetrics{acceptedEvents: 2, acceptedBytes: 400, insertedEvents: 1, filteredPassiveEvents: 1, lookupSubjects: 3, lookupBytes: 70})
	fields := wirePreprocessingLogValues(true, metrics.snapshot(), previous)
	got := make(map[string]any)
	for i := 0; i < len(fields); i += 2 {
		got[fields[i].(string)] = fields[i+1]
	}
	expected := map[string]any{
		"wire_preprocessing_enabled": true, "wire_input_batches": uint64(1), "wire_input_events": uint64(3),
		"wire_original_payload_bytes": uint64(800), "wire_compact_payload_bytes": uint64(600),
		"wire_committed_batches": uint64(1), "wire_accepted_submission_events": uint64(2),
		"wire_accepted_submission_payload_bytes": uint64(400), "wire_inserted_events": uint64(1),
		"wire_filtered_passive_events": uint64(1), "wire_lookup_subjects": uint64(3), "wire_lookup_subject_bytes": uint64(70),
	}
	if len(got) != len(expected) {
		t.Fatalf("unexpected metric dimensions: %v", got)
	}
	for name, value := range expected {
		if got[name] != value {
			t.Fatalf("metric %s = %v, want %v", name, got[name], value)
		}
	}
}

func TestEquivalentEscapedSubjectsShareOneLookup(t *testing.T) {
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
	events := []ingest.InboxEvent{
		wireSignal("app.bsky.feed.like", "create", `{"uri":"at://post"}`),
		wireSignal("app.bsky.feed.repost", "create", `{"uri":"at:\/\/post"}`),
		wireSignal("app.bsky.feed.like", "update", `{"uri":"at://p\u006fst"}`),
	}
	original := make([]string, len(events))
	for i, event := range events {
		original[i] = string(event.Payload)
	}
	mock.ExpectQuery("SELECT requested.ordinality").WithArgs(`["at://post"]`).WillReturnRows(sqlmock.NewRows([]string{"ordinality"}).AddRow(1))
	var metrics wireCommittedMetrics
	got, err := filterWireSignalsWithMetrics(context.Background(), tx, events, &metrics)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || metrics.lookupSubjects != 1 || metrics.lookupBytes != uint64(len(`["at://post"]`)) {
		t.Fatalf("equivalent subjects not deduplicated: %+v", metrics)
	}
	for i, event := range got {
		if string(event.Payload) != original[i] {
			t.Fatal("lookup normalization changed payload subject")
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
