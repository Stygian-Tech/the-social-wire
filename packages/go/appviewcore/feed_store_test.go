package appviewcore

import (
	"context"
	"database/sql"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"os"
	"testing"
	"time"
)

func fixtureDatabase(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires an isolated canonically migrated PostgreSQL database")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := db.PingContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestFeedMembershipDeduplicationAndReadAuthority(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:go-appview-%d", time.Now().UnixNano())
	other := viewer + "-other"
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/a"
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		for _, table := range []string{"appview_unread_overrides", "read_marks", "appview_publication_read_floors", "appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
	})
	for _, statement := range []string{
		`INSERT INTO appview_viewer_feeds(viewer_did,feed_kind,feed_id,updated_at) VALUES($1,'subscribed','',$4)`,
		`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`,
		`INSERT INTO appview_feed_publications(viewer_did,feed_kind,feed_id,publication_id) VALUES($1,'subscribed','',$2)`,
	} {
		// Statements use all four bound inputs via a parameter CTE, avoiding driver
		// ambiguity for parameters intentionally unused by an individual statement.
		if _, err := db.ExecContext(ctx, "WITH inputs AS (SELECT $1::text,$2::text,$3::text,$4::timestamptz) "+statement, viewer, publication, author, at); err != nil {
			t.Fatal(err)
		}
	}
	content := thinappviewcore.ContentStore{DB: db}
	for i := 0; i < 3; i++ {
		article := fmt.Sprintf("https://example.invalid/article/%d", i)
		item := thinappviewcore.IndexedContentItem{URI: fmt.Sprintf("at://%s/site.standard.document/%d", author, i), CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &publication, Render: thinappviewcore.ContentRenderFields{Title: fmt.Sprintf("Article %d", i), PublishedAt: at.Format(time.RFC3339), ArticleURL: &article}}
		if err := content.Upsert(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	store := FeedStore{DB: db}
	page, err := store.Feed(ctx, viewer, "subscribed", "", "all", "", 2, at)
	if err != nil {
		t.Fatal(err)
	}
	if page == nil || len(page.Response.Entries) != 2 || page.Response.Cursor == nil {
		t.Fatalf("unexpected first page: %#v", page)
	}
	next, err := store.Feed(ctx, viewer, "subscribed", "", "all", *page.Response.Cursor, 2, at)
	if err != nil || next == nil || len(next.Response.Entries) != 1 || next.Response.Cursor != nil {
		t.Fatalf("bad continuation: %#v %v", next, err)
	}
	missing, err := store.Feed(ctx, other, "subscribed", "", "all", "", 2, at)
	if err != nil || missing != nil {
		t.Fatalf("leaked membership to another viewer: %#v %v", missing, err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,read_floor_uri,generation) VALUES($1,$2,$3,NULL,1)`, viewer, publication, at); err != nil {
		t.Fatal(err)
	}
	unreadURI := page.Response.Entries[0].EntryID
	if _, err := db.ExecContext(ctx, `INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, unreadURI, at); err != nil {
		t.Fatal(err)
	}
	unreadPage, err := store.Feed(ctx, viewer, "subscribed", "", "unread", "", 100, at)
	if err != nil || unreadPage == nil || len(unreadPage.Response.Entries) != 1 || unreadPage.Response.Entries[0].EntryID != unreadURI {
		t.Fatalf("unread override/floor lost: %#v %v", unreadPage, err)
	}
	states, err := (ReadStateStore{DB: db}).ReadStates(ctx, viewer, page.Response.Entries)
	if err != nil || states[unreadURI] || !states[page.Response.Entries[1].EntryID] {
		t.Fatalf("read-state snapshot disagrees with feed: %v %v", states, err)
	}
}
