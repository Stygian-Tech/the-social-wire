package listcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"os"
	"testing"
	"time"
)

func TestPreparedListFeedUsesScopedMembershipAndFencedCursor(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("canonical PostgreSQL required")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	viewer := fmt.Sprintf("did:plc:listfeed%d", time.Now().UnixNano())
	author := viewer + "author"
	site := "at://" + author + "/site.standard.publication/a"
	id := Identity{viewer, "one"}.URI()
	at := time.Now().UTC().Truncate(time.Second)
	value, _ := json.Marshal(map[string]any{"name": "Fixture", "createdAt": at.Format(time.RFC3339), "publications": []string{site}})
	reader := fixtureReader{values: map[string]json.RawMessage{id: value}}
	runtime := NewRuntime(db, reader, nil)
	defer runtime.Close()
	ctx := context.Background()
	t.Cleanup(func() { db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author) })
	for i := 0; i < 3; i++ {
		item := thinappviewcore.IndexedContentItem{URI: fmt.Sprintf("at://%s/site.standard.document/%d", author, i), CID: "fixture", AuthorDID: author, Collection: "site.standard.document", PublicationSite: &site, CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}
		if e = (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); e != nil {
			t.Fatal(e)
		}
	}
	if _, _, e = runtime.PreparedFeed(id, viewer); e != ErrWarming {
		t.Fatalf("cold list %v", e)
	}
	deadline := time.Now().Add(time.Second)
	for {
		_, _, e = runtime.PreparedFeed(id, viewer)
		if e == nil {
			break
		}
		if e != ErrWarming || time.Now().After(deadline) {
			t.Fatalf("preparation %v", e)
		}
		time.Sleep(time.Millisecond)
	}
	page, e := runtime.Feed(ctx, gatewaycore.AuthContext{DID: viewer}, id, "all", "", 1, at)
	if e != nil || page == nil || len(page.Response.Entries) != 1 || page.Response.Cursor == nil {
		t.Fatalf("page %+v %v", page, e)
	}
	cursor := *page.Response.Cursor
	page, e = runtime.Feed(ctx, gatewaycore.AuthContext{DID: viewer}, id, "all", cursor, 50, at)
	if e != nil || len(page.Response.Entries) != 2 {
		t.Fatalf("next page %+v %v", page, e)
	}
	if _, e = runtime.Feed(ctx, gatewaycore.AuthContext{DID: viewer}, id, "unread", cursor, 50, at); e != ErrCursor {
		t.Fatalf("filter cursor accepted %v", e)
	}
}
