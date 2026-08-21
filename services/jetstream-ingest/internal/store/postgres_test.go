package store

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func testSource() ingest.SourceIdentity {
	return ingest.SourceIdentity{
		Environment: "dev", Host: "jetstream.us-west.bsky.network",
		StreamNSID:        "network.bsky.jetstream.subscribeEvents",
		FilterFingerprint: "filter", CursorKind: "jetstream_v2_seq", Generation: "west-v1",
	}
}

func wireTestSource() ingest.SourceIdentity {
	source := testSource()
	source.PipelineMode = config.WirePipelineMode
	source.Generation = config.WireSourceGeneration
	return source
}

func TestStageBatchCommitsInboxAndCheckpointAtomically(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	now := time.Unix(1_700_000_000, 0).UTC()
	event := ingest.InboxEvent{Seq: 7, Time: now, Kind: "commit", RepoDID: "did:plc:test", Payload: []byte(`{"cursor":7}`)}
	lease := Lease{Name: "jetstream-v2-ingest", OwnerID: "owner", FencingToken: 3}

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WithArgs("dev", lease.Name, "west-v1", lease.OwnerID, int64(3)).
		WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec("INSERT INTO appview_ingestion_inbox").
		WithArgs("dev", "west-v1", int64(7), "jetstream.us-west.bsky.network", "jetstream_v2_seq", "commit", "did:plc:test", nil, nil, nil, nil, nil, string(event.Payload), now).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").
		WithArgs("dev", "west-v1", "jetstream.us-west.bsky.network", "network.bsky.jetstream.subscribeEvents", "filter", "jetstream_v2_seq", int64(7), now, "live", int64(0), int64(0), int64(0), 0, 0, nil, now).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()

	err = store.StageBatch(context.Background(), lease, []ingest.InboxEvent{event}, 7, now, ReplayProgress{State: "live", LastProgressAt: now})
	if err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageBatchNormalizesUnsupportedUnicodeOnlyForWireInbox(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, wireTestSource())
	now := time.Unix(1_700_000_000, 0).UTC()
	event := ingest.InboxEvent{
		Seq: 7, Time: now, Kind: "commit", RepoDID: "did:plc:test",
		Payload: []byte(`{"record":{"text":"before\u0000after","literal":"\\u0000"}}`),
	}
	lease := Lease{Name: "wire-global-v1-ingest", OwnerID: "owner", FencingToken: 3}

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").
		WithArgs("dev", lease.Name, config.WireSourceGeneration, lease.OwnerID, int64(3)).
		WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec("INSERT INTO wire_ingestion_inbox").
		WithArgs(
			"dev", config.WireSourceGeneration, int64(7), "jetstream.us-west.bsky.network",
			"jetstream_v2_seq", "commit", "did:plc:test", nil, nil, nil, nil, nil,
			"{\"record\":{\"literal\":\"\\\\u0000\",\"text\":\"before�after\"}}", now,
		).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").
		WithArgs(
			"dev", config.WireSourceGeneration, "jetstream.us-west.bsky.network",
			"network.bsky.jetstream.subscribeEvents", "filter", "jetstream_v2_seq", int64(7),
			now, "live", int64(0), int64(0), int64(0), 0, 0, nil, now,
		).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()

	err = store.StageBatch(
		context.Background(), lease, []ingest.InboxEvent{event}, 7, now,
		ReplayProgress{State: "live", LastProgressAt: now},
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageBatchLeavesPublicationLanePayloadUnchanged(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	now := time.Unix(1_700_000_000, 0).UTC()
	event := ingest.InboxEvent{
		Seq: 7, Time: now, Kind: "commit", RepoDID: "did:plc:test",
		Payload: []byte(`{"record":{"text":"before\u0000after"}}`),
	}
	lease := Lease{Name: "jetstream-v2-ingest", OwnerID: "owner", FencingToken: 3}

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").
		WithArgs("dev", lease.Name, "west-v1", lease.OwnerID, int64(3)).
		WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec("INSERT INTO appview_ingestion_inbox").
		WithArgs(
			"dev", "west-v1", int64(7), "jetstream.us-west.bsky.network",
			"jetstream_v2_seq", "commit", "did:plc:test", nil, nil, nil, nil, nil,
			string(event.Payload), now,
		).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").
		WithArgs(
			"dev", "west-v1", "jetstream.us-west.bsky.network",
			"network.bsky.jetstream.subscribeEvents", "filter", "jetstream_v2_seq", int64(7),
			now, "live", int64(0), int64(0), int64(0), 0, 0, nil, now,
		).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()

	err = store.StageBatch(
		context.Background(), lease, []ingest.InboxEvent{event}, 7, now,
		ReplayProgress{State: "live", LastProgressAt: now},
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageBatchRollsBackWithoutAdvancingCheckpoint(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	now := time.Now().UTC()
	event := ingest.InboxEvent{Seq: 8, Time: now, Kind: "commit", RepoDID: "did:plc:test", Payload: []byte(`{}`)}
	lease := Lease{Name: "jetstream-v2-ingest", OwnerID: "owner", FencingToken: 3}

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec("INSERT INTO appview_ingestion_inbox").WillReturnError(errors.New("disk full"))
	mock.ExpectRollback()
	if err := store.StageBatch(context.Background(), lease, []ingest.InboxEvent{event}, 8, now, ReplayProgress{}); err == nil {
		t.Fatal("expected staging error")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestStageBatchUsesIdempotentSequenceConflict(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	now := time.Now().UTC()
	event := ingest.InboxEvent{Seq: 9, Time: now, Kind: "commit", RepoDID: "did:plc:test", Payload: []byte(`{}`)}
	lease := Lease{Name: "jetstream-v2-ingest", OwnerID: "owner", FencingToken: 3}

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnRows(sqlmock.NewRows([]string{"valid"}).AddRow(true))
	mock.ExpectExec(regexp.QuoteMeta("ON CONFLICT (environment, source_generation, seq) DO NOTHING")).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectExec("INSERT INTO appview_jetstream_checkpoints").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	if err := store.StageBatch(context.Background(), lease, []ingest.InboxEvent{event}, 9, now, ReplayProgress{}); err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestLoadCheckpointRejectsChangedIdentity(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	mock.ExpectQuery("SELECT source_host").WithArgs("dev", "west-v1").WillReturnRows(
		sqlmock.NewRows([]string{"source_host", "stream_nsid", "filter_fingerprint", "cursor_kind", "last_staged_seq", "replay_bytes_downloaded", "replay_state", "replay_retry_count", "replay_range_resume_count", "replay_etag", "last_staged_at", "replay_last_progress_at"}).
			AddRow("jetstream.us-east.bsky.network", "network.bsky.jetstream.subscribeEvents", "filter", "jetstream_v2_seq", int64(10), int64(0), "live", 0, 0, "", nil, nil),
	)
	if _, err := store.LoadCheckpoint(context.Background()); err == nil {
		t.Fatal("expected identity mismatch")
	}
}

func TestStageBatchRejectsStaleFencingTokenBeforeInboxWrite(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	lease := Lease{Name: "jetstream-v2-ingest", OwnerID: "old-owner", FencingToken: 2}
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT TRUE").WillReturnError(sql.ErrNoRows)
	mock.ExpectRollback()
	err = store.StageBatch(context.Background(), lease, nil, 10, time.Now().UTC(), ReplayProgress{})
	if !errors.Is(err, ErrLeaseUnavailable) {
		t.Fatalf("error = %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestTrackedDIDsUsesCurrentAuthorAndViewerScopes(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	mock.ExpectQuery("SELECT author_did AS repo_did").WillReturnRows(
		sqlmock.NewRows([]string{"repo_did"}).
			AddRow("did:plc:author").
			AddRow("did:plc:viewer"),
	)

	dids, err := store.TrackedDIDs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(dids) != 2 {
		t.Fatalf("tracked DIDs = %#v", dids)
	}
	for _, did := range []string{"did:plc:author", "did:plc:viewer"} {
		if _, ok := dids[did]; !ok {
			t.Fatalf("missing tracked DID %q", did)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestUpsertIncidentMergesExistingActiveIncident(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store := New(db, testSource())
	mock.ExpectBegin()
	mock.ExpectExec("SELECT pg_advisory_xact_lock").
		WithArgs("dev|west-v1|jetstream.us-west.bsky.network|consumer_too_slow").
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectQuery("SELECT id").
		WithArgs("dev", "west-v1", "jetstream.us-west.bsky.network", "jetstream_v2_seq", "consumer_too_slow").
		WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow("incident-1"))
	mock.ExpectExec("UPDATE appview_ingestion_incidents").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	err = store.UpsertIncident(context.Background(), IncidentSignal{
		Category: "consumer_too_slow", StartCursor: 40, EndCursor: 50,
		LastError: "ConsumerTooSlow", ReplayState: "recovering", RetryCount: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
