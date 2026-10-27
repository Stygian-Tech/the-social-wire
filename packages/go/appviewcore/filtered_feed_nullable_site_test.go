package appviewcore

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestFilteredFeedAllowsAuthorWideEntriesWithoutPublicationSite(t *testing.T) {
	db := fixtureDatabase(t)
	viewer := fmt.Sprintf("did:plc:nullable-feed-%d", time.Now().UnixNano())
	author := viewer + "-author"
	at := time.Now().UTC().Truncate(time.Second)
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
		db.Exec("DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1", viewer)
	})
	exec(`INSERT INTO appview_viewer_feeds VALUES($1,'subscribed','',$2)`, viewer, at)
	exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,scope_keys,updated_at) VALUES($1,'publication',$2,'[]',$3)`, viewer, author, at)
	exec(`INSERT INTO appview_feed_publications VALUES($1,'subscribed','','publication')`, viewer)
	// Both the initial cohort and a continuation refill must accept the optional
	// site field. More than sixteen records crosses the initial chunk boundary.
	exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,render_json,expires_at)
 SELECT 'at://'||$1||'/site.standard.document/'||i,'fixture',$1,'site.standard.document',$2::timestamptz-i*interval '1 second',$2,jsonb_build_object('title','Story '||i),$2::timestamptz+interval '1 hour' FROM generate_series(1,40)i`, author, at)
	store := FeedStore{DB: db}
	for _, filter := range []string{"all", "unread"} {
		page, err := store.Feed(context.Background(), viewer, "subscribed", "", filter, "", 30, at)
		if err != nil || page == nil || len(page.Response.Entries) != 30 || page.Response.Cursor == nil {
			t.Fatalf("%s first page: %#v %v", filter, page, err)
		}
		next, err := store.Feed(context.Background(), viewer, "subscribed", "", filter, *page.Response.Cursor, 30, at)
		if err != nil || next == nil || len(next.Response.Entries) != 10 || next.Response.Cursor != nil {
			t.Fatalf("%s continuation: %#v %v", filter, next, err)
		}
	}
	exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) SELECT $1,uri,$2 FROM content_items WHERE author_did=$3`, viewer, at, author)
	page, err := store.Feed(context.Background(), viewer, "subscribed", "", "read", "", 50, at)
	if err != nil || page == nil || len(page.Response.Entries) != 40 {
		t.Fatalf("read page: %#v %v", page, err)
	}
}
