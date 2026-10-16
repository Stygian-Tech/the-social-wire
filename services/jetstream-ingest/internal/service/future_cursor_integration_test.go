package service

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/coder/websocket"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

func TestPureLivePinnedSDKCursorErrorFramesAreHandledBeforeReconnect(t *testing.T) {
	for _, fixture := range []struct {
		code string
		want error
	}{{"FutureCursor", store.ErrSourceDiscontinuity}, {"CursorTooOld", errLiveCursorRequiresArchive}} {
		t.Run(fixture.code, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				if !strings.HasSuffix(request.URL.Path, "/network.bsky.jetstream.subscribeEvents") {
					http.NotFound(w, request)
					return
				}
				conn, err := websocket.Accept(w, request, nil)
				if err != nil {
					return
				}
				defer conn.CloseNow()
				ctx, cancel := context.WithTimeout(request.Context(), time.Second)
				defer cancel()
				_ = conn.Write(ctx, websocket.MessageText, []byte(`{"$type":"error","error":"`+fixture.code+`","message":"cursor rejected by source"}`))
				_, _, _ = conn.Read(ctx)
			}))
			defer server.Close()
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			mock.ExpectQuery("SELECT source_host, stream_nsid").WillReturnRows(sqlmock.NewRows([]string{"source_host"}))
			cfg := config.Config{PipelineMode: config.WirePipelineMode, Host: server.URL, APIKey: "fixture", SourceGeneration: "canonical", Collections: []string{"site.standard.document"}, WireAdmissionRate: 100, WireAdmissionBurst: 1, BatchSize: 1, DownloadConcurrency: 1, SegmentStripes: 1}
			runner := NewRunner(cfg, store.New(db, ingest.SourceFromConfig(cfg)), store.Lease{}, &health.State{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
			runner.liveOnly = true
			runner.liveCursor = 100
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := runner.runOnce(ctx); !errors.Is(err, fixture.want) {
				t.Fatalf("frame %s not classified before SDK reconnect: %v", fixture.code, err)
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
