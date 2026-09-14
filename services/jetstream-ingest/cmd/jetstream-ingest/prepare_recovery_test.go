package main

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

type recoveryNoHTTP struct{ calls atomic.Int64 }

func (r *recoveryNoHTTP) RoundTrip(*http.Request) (*http.Response, error) {
	r.calls.Add(1)
	return nil, fmt.Errorf("provider HTTP is forbidden during recovery preparation")
}

func TestPrepareRecoveryRejectsInvalidArgumentsBeforeConnecting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	for _, args := range [][]string{{"--prepare-wire-recovery"}, {"--lane", "wire"}, {"--prepare-wire-recovery", "--lane", "wire", "extra"}, {"--unknown"}} {
		if err := runArguments(args, logger); err == nil {
			t.Fatalf("accepted invalid options %v", args)
		}
	}
}

func TestPrepareRecoveryInitializesFreshRestoreWithoutProviderRequests(t *testing.T) {
	url := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	environment := "dev"
	generation := fmt.Sprintf("prepare-recovery-%d", time.Now().UnixNano())
	t.Setenv("APP_ENV", environment)
	t.Setenv("DATABASE_URL", url)
	t.Setenv("JETSTREAM_API_KEY", "")
	t.Setenv("JETSTREAM_APPVIEW_ENABLED", "false")
	t.Setenv("JETSTREAM_WIRE_ENABLED", "false")
	t.Setenv("JETSTREAM_WIRE_LANES", "publication")
	t.Setenv("JETSTREAM_WIRE_PUBLICATION_SOURCE_GENERATION", generation)
	t.Setenv("JETSTREAM_WIRE_PUBLICATION_ADMISSION_RATE_PER_SECOND", "100")
	t.Setenv("JETSTREAM_WIRE_PUBLICATION_ADMISSION_BURST_EVENTS", "100")
	lane, err := config.LoadWireRecovery("wire-publication")
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	defer func() {
		for _, table := range []string{"wire_publication_signal_recovery_jobs", "wire_ingestion_inbox_epochs", "wire_ingestion_recovery_anchors", "appview_jetstream_checkpoints", "appview_ingestion_leases"} {
			_, _ = db.Exec("DELETE FROM "+table+" WHERE environment=$1 AND source_generation=$2", environment, generation)
		}
	}()
	cfg := lane.Config
	_, err = db.Exec(`INSERT INTO appview_jetstream_checkpoints
		(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,replay_state,replay_bytes_downloaded)
		VALUES($1,$2,$3,$4,$5,$6,400,'live',1234)`, environment, cfg.SourceGeneration, cfg.Host, cfg.StreamNSID, cfg.FilterFingerprint, cfg.CursorKind)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO wire_ingestion_admission(environment,retained_rows,updated_at) VALUES($1,0,NOW()) ON CONFLICT DO NOTHING`, environment)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO wire_ingestion_recovery_anchors(environment,source_generation,anchor_bucket,checkpoint_seq,checkpoint_event_time,captured_at)
		VALUES($1,$2,date_trunc('hour',NOW()),100,NOW()-interval '7 days',NOW())`, environment, cfg.SourceGeneration)
	if err != nil {
		t.Fatal(err)
	}
	transport := &recoveryNoHTTP{}
	previous := http.DefaultTransport
	http.DefaultTransport = transport
	defer func() { http.DefaultTransport = previous }()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	args := []string{"--prepare-wire-recovery", "--lane", "wire-publication"}
	ownerDatabase, err := store.Open(context.Background(), url, ingest.SourceFromConfig(cfg))
	if err != nil {
		t.Fatal(err)
	}
	defer ownerDatabase.Close()
	liveLease, err := ownerDatabase.AcquireLease(context.Background(), cfg.LeaderLeaseName, "active-owner-fixture", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := runArguments(args, logger); err == nil {
		t.Fatal("preparation displaced an active ingestion owner")
	}
	if err := ownerDatabase.ReleaseLease(context.Background(), liveLease); err != nil {
		t.Fatal(err)
	}
	if err := runArguments(args, logger); err != nil {
		t.Fatal(err)
	}
	if err := runArguments(args, logger); err != nil {
		t.Fatalf("idempotent preparation: %v", err)
	}
	var jobs, activeLeases int
	var staged, downloaded int64
	if err := db.QueryRow(`SELECT COUNT(*) FROM wire_publication_signal_recovery_jobs WHERE environment=$1 AND source_generation=$2 AND maximum_source_seq=400`, environment, generation).Scan(&jobs); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT last_staged_seq,replay_bytes_downloaded FROM appview_jetstream_checkpoints WHERE environment=$1 AND source_generation=$2`, environment, generation).Scan(&staged, &downloaded); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM appview_ingestion_leases WHERE environment=$1 AND source_generation=$2 AND released_at IS NULL`, environment, generation).Scan(&activeLeases); err != nil {
		t.Fatal(err)
	}
	if jobs != 1 || staged != 100 || downloaded != 1234 || activeLeases != 0 || transport.calls.Load() != 0 {
		t.Fatalf("preparation changed unexpected state: jobs=%d staged=%d bytes=%d leases=%d http=%d", jobs, staged, downloaded, activeLeases, transport.calls.Load())
	}
}
