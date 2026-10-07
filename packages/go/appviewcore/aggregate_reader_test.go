package appviewcore

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestAggregateCursorContinuesAfterReturnedCapUsingFeedPosition(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	author := fmt.Sprintf("did:plc:aggregate%d", time.Now().UnixNano())
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() { db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author) })
	ids := []string{}
	for i := 0; i < 8; i++ {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		ids = append(ids, uri)
		// All publisher timestamps are intentionally unrelated to feed ordering.
		item := thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: fmt.Sprintf("Item %d", i), PublishedAt: at.Add(-24 * time.Hour).Format(time.RFC3339)}}
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	reader := ContentReader{DB: db}
	scoped, err := reader.ScopedEntries(ctx, author, []PublicationScope{{PublicationID: author, AuthorDID: author}}, "all", "", 5, at)
	if err != nil || len(scoped.Response.Entries) != 5 || scoped.Response.Cursor == nil {
		t.Fatalf("author scope aggregation: %#v %v", scoped, err)
	}
	scopedNext, err := reader.ScopedEntries(ctx, author, []PublicationScope{{PublicationID: author, AuthorDID: author}}, "all", *scoped.Response.Cursor, 5, at)
	if err != nil || len(scopedNext.Response.Entries) != 3 || scopedNext.Response.Entries[0].EntryID != ids[5] {
		t.Fatalf("author scope continuation: %#v %v", scopedNext, err)
	}
	query := EntryQuery{ViewerDID: author, AuthorDID: author, Filter: "all", Limit: 3}
	page, err := reader.EntriesUpTo(ctx, query, 5, at)
	if err != nil || len(page.Entries) != 5 || page.Cursor == nil {
		t.Fatalf("aggregate: %#v %v", page, err)
	}
	position, err := DecodeEntryCursor(*page.Cursor)
	if err != nil || position.URI != ids[4] || !position.CreatedAt.Equal(at.Add(-4*time.Second)) {
		t.Fatalf("wrong capped position: %#v %v", position, err)
	}
	query.Cursor = *page.Cursor
	next, err := reader.Entries(ctx, query, at)
	if err != nil || len(next.Entries) != 3 || next.Entries[0].EntryID != ids[5] || next.Cursor != nil {
		t.Fatalf("skipped capped overflow: %#v %v", next, err)
	}
}
