package runtime

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

func readinessDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL")
	if dsn == "" {
		dsn = os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("canonical PostgreSQL not configured")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(12)
	t.Cleanup(func() { db.Close() })
	return db
}
func readinessViewer(t *testing.T, db *sql.DB, viewer string) {
	t.Helper()
	manifest := r.Manifest{Type: r.ManifestCollection, Version: 1, Generation: "runtime-test", LastSequence: 0}
	raw, _ := json.Marshal(manifest)
	cid, _ := r.RecordCID(raw)
	if _, err := db.Exec(`INSERT INTO appview_pds_read_state_authority(viewer_did,manifest,manifest_cid,projection_ready,last_accessed_at)VALUES($1,$2::jsonb,$3,FALSE,$4)`, viewer, raw, cid, time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM appview_ingestion_leases WHERE environment='dev' AND source_generation='pds-read-state-rebuild-v1'`)
	})
}
func TestReadStateRecoveryGlobalSlotsAndTouchCoalescing(t *testing.T) {
	db := readinessDB(t)
	store := &pdsreadstatecore.Store{DB: db}
	viewers := []string{"did:plc:runtime-ready-one", "did:plc:runtime-ready-two", "did:plc:runtime-ready-three"}
	for _, viewer := range viewers {
		readinessViewer(t, db, viewer)
	}
	started := make(chan string, 3)
	release := make(chan struct{})
	var invalidated atomic.Int64
	coordinators := []*Readiness{}
	for range 3 {
		c := NewReadiness(context.Background(), store, "dev", func(context.Context, string) error { invalidated.Add(1); return nil })
		c.Rebuild = func(ctx context.Context, viewer string) (bool, error) {
			started <- viewer
			select {
			case <-release:
				_, err := db.ExecContext(ctx, `UPDATE appview_pds_read_state_authority SET projection_ready=TRUE WHERE viewer_did=$1`, viewer)
				return err == nil, err
			case <-ctx.Done():
				return false, ctx.Err()
			}
		}
		coordinators = append(coordinators, c)
		t.Cleanup(c.Close)
	}
	for i := 0; i < 2; i++ {
		if err := coordinators[i].RequireReady(context.Background(), viewers[i]); !errors.Is(err, pdsreadstatecore.ErrProjectionUnavailable) {
			t.Fatal(err)
		}
		select {
		case <-started:
		case <-time.After(3 * time.Second):
			t.Fatal("slot did not start")
		}
	}
	if err := coordinators[2].RequireReady(context.Background(), viewers[2]); !errors.Is(err, pdsreadstatecore.ErrProjectionUnavailable) {
		t.Fatal(err)
	}
	coordinators[2].wg.Wait()
	select {
	case <-started:
		t.Fatal("third replica exceeded durable slots")
	default:
	}
	if invalidated.Load() != 2 {
		t.Fatal(invalidated.Load())
	}
	var touched time.Time
	if err := db.QueryRow(`SELECT last_accessed_at FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewers[0]).Scan(&touched); err != nil {
		t.Fatal(err)
	}
	if time.Since(touched) > time.Minute {
		t.Fatal(touched)
	}
	if err := store.Touch(context.Background(), viewers[0], touched.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var again time.Time
	db.QueryRow(`SELECT last_accessed_at FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewers[0]).Scan(&again)
	if !again.Equal(touched) {
		t.Fatal("touch was not coalesced", again, touched)
	}
	close(release)
	for i := 0; i < 2; i++ {
		coordinators[i].wg.Wait()
		if err := coordinators[i].RequireReady(context.Background(), viewers[i]); err != nil {
			t.Fatal(err)
		}
	}
	var unreleased int
	if err := db.QueryRow(`SELECT count(*) FROM appview_ingestion_leases WHERE environment='dev' AND source_generation='pds-read-state-rebuild-v1' AND released_at IS NULL`).Scan(&unreleased); err != nil || unreleased != 0 {
		t.Fatal(unreleased, err)
	}
}
func TestReadStateMiddlewareStatusAndExportStayAccessible(t *testing.T) {
	db := readinessDB(t)
	viewer := "did:plc:runtime-ready-middleware"
	readinessViewer(t, db, viewer)
	coordinator := NewReadiness(context.Background(), &pdsreadstatecore.Store{DB: db}, "dev", nil)
	coordinator.Rebuild = func(ctx context.Context, _ string) (bool, error) { <-ctx.Done(); return false, ctx.Err() }
	t.Cleanup(coordinator.Close)
	handler := coordinator.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	for _, entry := range []struct {
		path string
		code int
	}{{"/v1/appview/bootstrap-stream", 503}, {"/v1/publications/sidebar", 503}, {"/xrpc/app.thesocialwire.appview.getReadStateStatus", 204}, {"/xrpc/app.thesocialwire.appview.exportReadState", 204}, {"/xrpc/app.thesocialwire.discovery.getSports", 204}} {
		req := httptest.NewRequest("GET", entry.path, nil)
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: viewer}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != entry.code {
			t.Fatal(entry, w.Code, w.Body.String())
		}
	}
	coordinator.Close()
}
