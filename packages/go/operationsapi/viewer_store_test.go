package operationsapi

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestViewerHistoryTracksProjectionUnionAndLatestUTCObservation(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, _ := NewPostgresStore(tx, "dev")
	at := time.Date(2031, 3, 8, 12, 0, 0, 0, time.UTC)
	fixture, _ := randomUUID()
	baseline, err := store.FetchViewerCounts(ctx, at)
	if err != nil {
		t.Fatal(err)
	}
	for i, age := range []time.Duration{0, 8 * 24 * time.Hour, 31 * 24 * time.Hour} {
		id := fixture + string(rune('a'+i))
		if _, err = tx.Exec(ctx, `INSERT INTO appview_viewer_feeds(viewer_did,feed_kind,updated_at) VALUES($1,'subscribed',$2)`, id, at.Add(-age)); err != nil {
			t.Fatal(err)
		}
	}
	counts, err := store.FetchViewerCounts(ctx, at)
	if err != nil || counts.KnownViewers != baseline.KnownViewers+3 || counts.ActiveViewers7d != baseline.ActiveViewers7d+1 || counts.ActiveViewers30d != baseline.ActiveViewers30d+2 {
		t.Fatal(counts, baseline, err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,updated_at) VALUES($1,'fixture','did:plc:fixture',$2)`, fixture+"c", at); err != nil {
		t.Fatal(err)
	}
	counts, err = store.FetchViewerCounts(ctx, at)
	if err != nil || counts.KnownViewers != baseline.KnownViewers+3 || counts.ActiveViewers7d != baseline.ActiveViewers7d+2 || counts.ActiveViewers30d != baseline.ActiveViewers30d+3 {
		t.Fatal("projection union double counted viewer", counts, err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM operations_viewer_daily_counts WHERE environment IN ('dev','prod')`); err != nil {
		t.Fatal(err)
	}
	for _, value := range []ViewerCounts{{KnownViewers: 10, ActiveViewers7d: 4, ActiveViewers30d: 7, ObservedAt: WireTime{at.Add(time.Hour)}}, {KnownViewers: 1, ObservedAt: WireTime{at}}, {KnownViewers: 5, ObservedAt: WireTime{at.Add(-90 * 24 * time.Hour)}}, {KnownViewers: 20, ObservedAt: WireTime{at.Add(24 * time.Hour)}}} {
		if err = store.SaveViewerHistory(ctx, value); err != nil {
			t.Fatal(err)
		}
	}
	history, err := store.FetchViewerHistory(ctx, at.Add(2*time.Hour))
	if err != nil || len(history) != 1 || history[0].KnownViewers != 10 {
		t.Fatal("stale, future, or expired sample shown", history, err)
	}
	if err = store.RecordViewerHistory(ctx, at.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	var old int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM operations_viewer_daily_counts WHERE environment='dev' AND snapshot_day<($1::timestamptz AT TIME ZONE 'UTC')::date-89`, at).Scan(&old); err != nil || old != 0 {
		t.Fatal("retention did not prune history", old, err)
	}
}
