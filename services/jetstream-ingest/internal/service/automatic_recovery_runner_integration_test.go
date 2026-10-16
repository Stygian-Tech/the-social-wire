package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

func TestAutomaticRecoveryRunnerKeepsLiveIntakeDuringArchivePauseIntegration(t *testing.T) {
	for _, failure := range []string{"paused_budget", "expired"} {
		t.Run(failure, func(t *testing.T) {
			databaseURL := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
			if databaseURL == "" {
				t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			db, err := sql.Open("pgx", databaseURL)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			liveEvents := make(chan uint64, 2)
			var liveConnections, archiveRequests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				switch request.URL.Path {
				case "/xrpc/network.bsky.jetstream.subscribeEvents":
					conn, err := websocket.Accept(w, request, &websocket.AcceptOptions{Subprotocols: []string{"xrpc.v1.json"}})
					if err != nil {
						return
					}
					defer conn.CloseNow()
					liveConnections.Add(1)
					connectionCtx := conn.CloseRead(ctx)
					for {
						select {
						case <-connectionCtx.Done():
							return
						case seq := <-liveEvents:
							frame := map[string]any{"$type": "message", "payload": map[string]any{
								"$type": "network.bsky.jetstream.subscribeEvents#account", "seq": seq,
								"did": "did:plc:automaticrunner", "time": time.Now().UTC().Format(time.RFC3339Nano),
								"account": map[string]any{"did": "did:plc:automaticrunner", "active": true, "status": "active"},
							}}
							payload, _ := json.Marshal(frame)
							if err := conn.Write(connectionCtx, websocket.MessageText, payload); err != nil {
								return
							}
						}
					}
				case "/xrpc/network.bsky.jetstream.planSnapshot":
					archiveRequests.Add(1)
					_, _ = io.Copy(io.Discard, request.Body)
					if failure == "expired" {
						select {
						case <-request.Context().Done():
						case <-ctx.Done():
						}
						return
					}
					w.Header().Set("Content-Type", "application/json")
					// Even a plan response consumes the parent's archive allowance.
					_, _ = io.WriteString(w, `{"plannedThroughSeq":200,"sealedTipSeq":200,"segments":[{"name":"fixture","index":0,"minSeq":100,"maxSeq":200,"mode":"segment","checksum":"fixture"}],"stats":{"segmentsExamined":1,"segmentsMatched":1,"blocksMatched":0,"entries":1}}`+strings.Repeat(" ", 1024))
				default:
					http.Error(w, `{"error":"NotFound"}`, http.StatusNotFound)
				}
			}))
			defer server.Close()
			bootstrap := uint64(100)
			cfg := config.Config{
				PipelineMode: config.WirePipelineMode, AutomaticRecoveryEnabled: true,
				Environment:      fmt.Sprintf("automatic-runner-%s-%d", failure, time.Now().UnixNano()),
				SourceGeneration: "canonical-parent", Host: server.URL, StreamNSID: "network.bsky.jetstream.subscribeEvents",
				FilterFingerprint: "publication-only", CursorKind: "jetstream_v2_seq", Collections: []string{"site.standard.document"},
				APIKey: "fixture", BootstrapAfterSeq: &bootstrap, BatchSize: 1, DownloadConcurrency: 1, SegmentStripes: 1,
				ReplayIncidentBytes: 16, ReplayDailyBytes: 1 << 20, BackoffMin: 10 * time.Millisecond, BackoffMax: 50 * time.Millisecond,
				WireAdmissionRate: 1000, WireAdmissionBurst: 1,
			}
			if failure == "expired" {
				expiry := time.Now().Add(3 * time.Second)
				cfg.ReplayCanaryExpiresAt = &expiry
				cfg.ReplayIncidentBytes = 1 << 20
			}
			t.Cleanup(func() {
				cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
				defer stop()
				cleanupDB, err := sql.Open("pgx", databaseURL)
				if err != nil {
					t.Error(err)
					return
				}
				defer cleanupDB.Close()
				for _, table := range []string{"ingestion_recovery_jobs", "ingestion_poison_records", "ingestion_recovery_controllers", "wire_ingestion_inbox", "wire_ingestion_recovery_anchors", "appview_ingestion_replay_usage", "appview_jetstream_checkpoints", "appview_ingestion_leases", "wire_ingestion_admission"} {
					if _, err := cleanupDB.ExecContext(cleanup, "DELETE FROM "+table+" WHERE environment=$1", cfg.Environment); err != nil {
						t.Errorf("cleanup %s: %v", table, err)
					}
				}
			})
			if _, err := db.ExecContext(ctx, "INSERT INTO wire_ingestion_admission(environment,retained_rows) VALUES($1,0)", cfg.Environment); err != nil {
				t.Fatal(err)
			}
			p := store.New(db, ingest.SourceFromConfig(cfg))
			p.ConfigureWireCompactIngest(true)
			p.ConfigureWireAdmission(100000, 1<<40)
			lease, err := p.AcquireLease(ctx, "parent", "fixture", time.Minute)
			if err != nil {
				t.Fatal(err)
			}
			runner := NewRunner(cfg, p, lease, &health.State{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
			finished := make(chan error, 1)
			go func() { finished <- runner.Run(ctx) }()
			defer func() {
				cancel()
				select {
				case err := <-finished:
					if err != nil {
						t.Errorf("runner shutdown: %v", err)
					}
				case <-time.After(5 * time.Second):
					t.Error("runner did not join live and recovery workers after cancellation")
				}
			}()
			liveEvents <- 200
			waitAutomaticRunner(t, ctx, func() bool {
				var status string
				return db.QueryRowContext(ctx, "SELECT status FROM ingestion_recovery_jobs WHERE environment=$1", cfg.Environment).Scan(&status) == nil && status == failure
			})
			if archiveRequests.Load() == 0 {
				t.Fatal("historical recovery never reached the mocked archive")
			}
			// Once historical recovery is durably stopped, a new real WebSocket
			// event must still pass through the SDK and canonical inbox/checkpoint.
			liveEvents <- 201
			waitAutomaticRunner(t, ctx, func() bool {
				checkpoint, err := p.LoadCheckpoint(ctx)
				return err == nil && checkpoint != nil && checkpoint.LastStagedSeq != nil && *checkpoint.LastStagedSeq == 201
			})
			var rows int
			if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM wire_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq IN(200,201)", cfg.Environment, cfg.SourceGeneration).Scan(&rows); err != nil || rows != 2 {
				t.Fatalf("live canonical rows=%d err=%v", rows, err)
			}
			if liveConnections.Load() != 1 {
				t.Fatalf("archive failure restarted live connection: %d", liveConnections.Load())
			}
		})
	}
}

func waitAutomaticRunner(t *testing.T, ctx context.Context, condition func() bool) {
	t.Helper()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for !condition() {
		select {
		case <-ctx.Done():
			t.Fatal("automatic runner did not reach expected durable state before deadline")
		case <-ticker.C:
		}
	}
}
