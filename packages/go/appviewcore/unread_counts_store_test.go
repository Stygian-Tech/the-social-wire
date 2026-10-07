package appviewcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"strings"
	"testing"
	"time"
)

func TestLegacyUnreadCountUsesViewerStateAndScope(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Second)
	viewer := fmt.Sprintf("did:plc:unreadquery%d", at.UnixNano())
	other := viewer + "other"
	author := viewer + "author"
	pub := "at://" + author + "/site.standard.publication/a"
	otherPub := "at://" + author + "/site.standard.publication/b"
	uris := []string{}
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=ANY($1::text[])", []string{viewer, other})
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
	})
	for i, site := range []string{pub, pub, otherPub} {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		uris = append(uris, uri)
		if e := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at, IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &site, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}); e != nil {
			t.Fatal(e)
		}
	}
	if _, e := db.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at)VALUES($1,$2,$3)`, viewer, uris[0], at); e != nil {
		t.Fatal(e)
	}
	reader := ContentReader{DB: db}
	scoped := PublicationScope{AuthorDID: author, PublicationATURI: &pub}
	for _, tc := range []struct {
		viewer string
		scope  PublicationScope
		want   int
	}{{viewer, scoped, 1}, {other, scoped, 2}, {viewer, PublicationScope{AuthorDID: author}, 2}, {viewer, PublicationScope{AuthorDID: other}, 0}} {
		n, e := reader.ScopedUnreadCount(ctx, tc.viewer, tc.scope, at)
		if e != nil || n != tc.want {
			t.Fatal(tc, n, e)
		}
	}
	empty := ""
	scoped.PublicationATURI = &empty
	n, e := reader.ScopedUnreadCount(ctx, viewer, scoped, at)
	if e != nil || n != 0 {
		t.Fatal("empty explicit scope must not become whole author", n, e)
	}
}
func TestUnreadResponseDatesAndLegacyMetadataAbsence(t *testing.T) {
	at := time.Date(2026, 10, 7, 3, 4, 5, 987654321, time.UTC)
	b, e := json.Marshal(UnreadCountsResponse{Counts: map[string]int{"a": 1}, CountedAt: &at})
	if e != nil || !strings.Contains(string(b), `"countedAt":"2026-10-07T03:04:05Z"`) {
		t.Fatal(string(b), e)
	}
	b, _ = json.Marshal(UnreadCountsResponse{Counts: map[string]int{}})
	if string(b) != `{"counts":{}}` {
		t.Fatal(string(b))
	}
}
