package service

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

func recoveryAdmissionFixture(t *testing.T, pause time.Duration) (*Runner, sqlmock.Sqlmock, ingest.InboxEvent) {
	t.Helper()
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	cfg := config.Config{PipelineMode: config.WirePipelineMode, Environment: "dev", SourceGeneration: "held", Host: "fixture.example", ReplaySnapshotOnly: true, WireAdmissionRate: 0.001, WireAdmissionBurst: 1, WireAdmissionPause: pause}
	p := store.New(db, ingest.SourceFromConfig(cfg))
	p.ConfigureWireCompactIngest(true)
	p.ConfigureWireAdmission(100, 1<<40)
	runner := NewRunner(cfg, p, store.Lease{}, &health.State{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	runner.sharedRecoveryBudget = true
	event := ingest.InboxEvent{Seq: 42, Time: time.Now().UTC(), Kind: "account", RepoDID: "did:plc:held", Payload: []byte(`{"account":{"active":true}}`)}
	return runner, mock, event
}
func expectRecoveryCapacity(mock sqlmock.Sqlmock) {
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectQuery("SELECT retained_rows, pg_database_size").WillReturnRows(sqlmock.NewRows([]string{"rows", "bytes"}).AddRow(100, 1))
	mock.ExpectExec("INSERT INTO wire_ingestion_inbox").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectRollback()
}

func TestRecoveryAdmissionHoldsPreparedChunkWithoutRepeatingReservation(t *testing.T) {
	runner, mock, event := recoveryAdmissionFixture(t, time.Millisecond)
	expectRecoveryCapacity(mock)
	expectRecoveryCapacity(mock)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectQuery("SELECT retained_rows, pg_database_size").WillReturnRows(sqlmock.NewRows([]string{"rows", "bytes"}).AddRow(0, 1))
	mock.ExpectExec("INSERT INTO wire_ingestion_inbox").WithArgs("dev", "held", int64(42), "fixture.example", "", "account", "did:plc:held", nil, nil, nil, nil, nil, string(event.Payload), event.Time).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE wire_ingestion_admission").WithArgs("dev", int64(1)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO wire_ingestion_recovery_anchors").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runner.stagePreparedBatch(ctx, []ingest.InboxEvent{event}, event.Seq, event.Time, store.ReplayProgress{State: "replaying", BytesDownloaded: 1234}); err != nil {
		t.Fatal(err)
	}
	// Reserving this one event again would have imposed 1000 seconds of pacing,
	// rather than the two millisecond admission pauses observed above.
	wait, err := runner.admissionLimiter.Reserve(1, time.Now())
	if err != nil || wait < 990*time.Second || wait > 1001*time.Second {
		t.Fatalf("rate reservation was repeated or replenished: %s %v", wait, err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryAdmissionCancellationKeepsFailedChunkUncommitted(t *testing.T) {
	runner, mock, event := recoveryAdmissionFixture(t, time.Hour)
	expectRecoveryCapacity(mock)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := runner.stagePreparedBatch(ctx, []ingest.InboxEvent{event}, event.Seq, event.Time, store.ReplayProgress{}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("held admission ignored canary/context: %v", err)
	}
	// No checkpoint update, commit, second reservation, or second transaction.
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryAdmissionDoesNotHideLeaseLoss(t *testing.T) {
	runner, mock, event := recoveryAdmissionFixture(t, time.Millisecond)
	expectRecoveryCapacity(mock)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}))
	mock.ExpectRollback()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runner.stagePreparedBatch(ctx, []ingest.InboxEvent{event}, event.Seq, event.Time, store.ReplayProgress{}); !errors.Is(err, store.ErrLeaseUnavailable) {
		t.Fatalf("lost lease was retried as capacity: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryAdmissionPropagatesStorageFailures(t *testing.T) {
	runner, mock, event := recoveryAdmissionFixture(t, time.Millisecond)
	expectRecoveryCapacity(mock)
	failed := errors.New("storage unavailable")
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectQuery("SELECT retained_rows, pg_database_size").WillReturnError(failed)
	mock.ExpectRollback()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runner.stagePreparedBatch(ctx, []ingest.InboxEvent{event}, event.Seq, event.Time, store.ReplayProgress{}); !errors.Is(err, failed) {
		t.Fatalf("storage failure was hidden as admission pause: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
