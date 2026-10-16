package appviewcore

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

func TestSparseFeedProductionScale(t *testing.T) {
	for _, size := range []int{30000, 50000} {
		t.Run(fmt.Sprint(size), func(t *testing.T) { testSparseFeedScale(t, size) })
	}
}

func testSparseFeedScale(t *testing.T, size int) {
	db := fixtureDatabase(t)
	viewer := fmt.Sprintf("did:plc:feed-scale-%d", time.Now().UnixNano())
	at := time.Now().UTC().Truncate(time.Second)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_publication_read_floors", "appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did LIKE $1", viewer+"-author-%")
	})
	exec(`INSERT INTO appview_viewer_feeds VALUES($1,'subscribed','',$2)`, viewer, at)
	exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,scope_keys,updated_at) SELECT $1,'pub-'||i,$1||'-author-'||i,CASE WHEN i<=63 THEN jsonb_build_array('site-'||i,'alias-'||i) ELSE jsonb_build_array('site-'||i) END,$2 FROM generate_series(1,80)i`, viewer, at)
	exec(`INSERT INTO appview_feed_publications SELECT $1,'subscribed','',publication_id FROM appview_publication_scopes WHERE viewer_did=$1`, viewer)
	exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) SELECT 'at://'||$1||'-author-'||(1+(i%80))||'/site.standard.document/'||i,'fixture',$1||'-author-'||(1+(i%80)),'site.standard.document',$2::timestamptz-i*interval '1 second',$2,'site-'||(1+(i%80)),jsonb_build_object('title','Entry '||i,'articleUrl','https://scale.invalid/'||i,'summary',repeat('fixture ',64)),$2::timestamptz+interval '1 hour' FROM generate_series(1,$3::integer)i`, viewer, at, size)
	// Floors model a fully read publication history without tens of thousands of
	// per-record mutation triggers during fixture setup and cleanup.
	exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,generation) SELECT $1,publication_id,$2,1 FROM appview_publication_scopes WHERE viewer_did=$1`, viewer, at)
	oldest := fmt.Sprintf("at://%s-author-%d/site.standard.document/%d", viewer, 1+size%80, size)
	exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, oldest, at)
	exec("VACUUM(ANALYZE) content_items")
	for _, table := range []string{"read_marks", "appview_publication_scopes", "appview_publication_scope_keys", "appview_feed_publications"} {
		exec("ANALYZE " + table)
	}
	config, err := pgx.ParseConfig(os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int64
	counted := sql.OpenDB(feedCountingConnector{Connector: stdlib.GetConnector(*config), calls: &calls})
	defer counted.Close()
	// A dense first page must still complete with the initial page-sized query.
	page, err := (FeedStore{DB: counted}).Feed(context.Background(), viewer, "subscribed", "", "all", "", 50, at)
	if err != nil || page == nil || len(page.Response.Entries) != 50 || calls.Load() != 1 {
		t.Fatalf("dense first page: %#v %v calls=%d", page, err, calls.Load())
	}
	budget := 30 * time.Second
	if raw := os.Getenv("SOCIALWIRE_GO_FEED_SCALE_BUDGET"); raw != "" {
		var err error
		budget, err = time.ParseDuration(raw)
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, unread := range []int{1, 0} {
		if unread == 0 {
			exec(`DELETE FROM appview_unread_overrides WHERE viewer_did=$1`, viewer)
		}
		calls.Store(0)
		ctx, cancel := context.WithTimeout(context.Background(), budget)
		start := time.Now()
		page, err := (FeedStore{DB: counted}).Feed(ctx, viewer, "subscribed", "", "unread", "", 50, at)
		elapsed := time.Since(start)
		cancel()
		rows := -1
		if page != nil {
			rows = len(page.Response.Entries)
		}
		t.Logf("content=%d scopes=143 pubs=80 expectedUnread=%d returned=%d duration=%s queries=%d error=%v", size, unread, rows, elapsed, calls.Load(), err)
		if err != nil || page == nil || rows != unread || page.Response.Cursor != nil {
			t.Fatalf("sparse exhaustion: %#v %v", page, err)
		}
		if unread == 1 && page.Response.Entries[0].EntryID != oldest {
			t.Fatal("oldest unread lost")
		}
		if calls.Load() > int64(10+size/512) {
			t.Fatalf("sparse query count regressed: %d", calls.Load())
		}
	}
}
