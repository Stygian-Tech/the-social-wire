package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestStageBatchRetriesAdmissionAndCheckpointConflicts(t *testing.T) {
	for _, test := range []struct {
		name          string
		wire, compact bool
	}{
		{"compact Wire", true, true}, {"legacy Wire", true, false}, {"AppView", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			source := testSource()
			if test.wire {
				source = wireTestSource()
			}
			p := New(db, source)
			p.ConfigureWireCompactIngest(test.compact)
			p.ConfigureWireAdmission(1000, 1<<40)
			now := time.Unix(1700000000, 0).UTC()
			event := ingest.InboxEvent{Seq: 42, Time: now, Kind: "account", RepoDID: "did:plc:test", Payload: []byte(`{"account":{"active":true}}`)}
			for attempt := 0; attempt < 3; attempt++ {
				mock.ExpectBegin()
				mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
				if test.wire {
					capacity := mock.ExpectQuery("SELECT retained_rows, pg_database_size").WithArgs(source.Environment)
					if attempt == 0 {
						capacity.WillReturnError(&pgconn.PgError{Code: "40001"})
						mock.ExpectRollback()
						continue
					}
					capacity.WillReturnRows(sqlmock.NewRows([]string{"retained_rows", "database_bytes"}).AddRow(200, 1024))
				}
				table := "appview_ingestion_inbox"
				if test.wire {
					table = "wire_ingestion_inbox"
				}
				mock.ExpectExec("INSERT INTO "+table).WithArgs(source.Environment, source.Generation, int64(42), source.Host, source.CursorKind, event.Kind, event.RepoDID, nil, nil, nil, nil, nil, string(event.Payload), now).WillReturnResult(sqlmock.NewResult(0, 1))
				if test.wire {
					mock.ExpectExec("UPDATE wire_ingestion_admission").WithArgs(source.Environment, int64(1)).WillReturnResult(sqlmock.NewResult(0, 1))
					mock.ExpectExec("INSERT INTO wire_ingestion_recovery_anchors").WillReturnResult(sqlmock.NewResult(0, 1))
				}
				checkpoint := mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WithArgs(source.Environment, source.Generation, source.Host, source.StreamNSID, source.FilterFingerprint, source.CursorKind, int64(42), now, "live", int64(0), nil, int64(0), int64(1234), 0, 0, nil, now)
				if attempt < 2 {
					code := "40P01"
					if attempt == 0 {
						code = "40001"
					}
					checkpoint.WillReturnError(&pgconn.PgError{Code: code})
					mock.ExpectRollback()
				} else {
					checkpoint.WillReturnResult(sqlmock.NewResult(0, 1))
					mock.ExpectCommit()
				}
			}
			if err := p.StageBatch(context.Background(), Lease{}, []ingest.InboxEvent{event}, 42, now, ReplayProgress{State: "live", BytesDownloaded: 1234, LastProgressAt: now}); err != nil {
				t.Fatal(err)
			}
			if test.compact {
				metrics := p.wirePreprocessing.snapshot()
				if metrics.inputBatches != 1 || metrics.committedBatches != 1 || metrics.insertedEvents != 1 {
					t.Fatalf("retries inflated committed metrics: %+v", metrics)
				}
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestStageRetryHandlesWrappedDeadlockAndCancelsBackoff(t *testing.T) {
	for _, code := range []string{"40001", "40P01"} {
		t.Run(code, func(t *testing.T) {
			attempts := 0
			if err := retryStageSerialization(context.Background(), func() error {
				attempts++
				if attempts < 6 {
					return fmt.Errorf("transaction: %w", &pgconn.PgError{Code: code})
				}
				return nil
			}); err != nil || attempts != 6 {
				t.Fatalf("wrapped conflict: attempts=%d err=%v", attempts, err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			attempts = 0
			err := retryStageSerialization(ctx, func() error { attempts++; cancel(); return &pgconn.PgError{Code: code} })
			if !errors.Is(err, context.Canceled) || attempts != 1 {
				t.Fatalf("cancel during backoff: attempts=%d err=%v", attempts, err)
			}
		})
	}
}
