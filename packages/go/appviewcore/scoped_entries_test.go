package appviewcore

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestScopedEntriesUseFirstMatchingPublicationFloorAndDedupeURLs(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:scoped%d", time.Now().UnixNano())
	author := viewer + "-author"
	at := time.Now().UTC().Truncate(time.Second)
	site := "https://publisher.invalid/feed"
	publicationA, publicationB := "a-broad-"+viewer, "b-specific-"+viewer
	t.Cleanup(func() {
		db.Exec(`DELETE FROM appview_publication_read_floors WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	for i := 0; i < 3; i++ {
		link := fmt.Sprintf("https://publisher.invalid/article/%d", i/2)
		item := thinappviewcore.IndexedContentItem{URI: fmt.Sprintf("at://%s/site.standard.document/%d", author, i), CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &site, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", ArticleURL: &link, PublishedAt: at.Format(time.RFC3339)}}
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,generation) VALUES($1,$2,$3,1)`, viewer, publicationA, at); err != nil {
		t.Fatal(err)
	}
	scopes := []PublicationScope{{PublicationID: publicationB, AuthorDID: author, PublicationSiteURLs: []string{site}}, {PublicationID: publicationA, AuthorDID: author}}
	reader := ContentReader{DB: db}
	page, err := reader.ScopedEntries(ctx, viewer, scopes, "read", "", 50, at)
	if err != nil || len(page.Response.Entries) != 2 || page.Response.Entries[0].PublicationID == nil || *page.Response.Entries[0].PublicationID != publicationA {
		t.Fatalf("scope sorting/dedupe: %#v %v", page, err)
	}
	page, err = reader.ScopedEntries(ctx, viewer, scopes[:1], "unread", "", 50, at)
	if err != nil || len(page.Response.Entries) != 2 {
		t.Fatalf("inherited other publication floor: %#v %v", page, err)
	}
	page, err = reader.ScopedEntries(ctx, viewer, []PublicationScope{{PublicationID: publicationB, AuthorDID: author, PublicationSiteURLs: []string{"https://other.invalid/feed"}}}, "all", "", 50, at)
	if err != nil || len(page.Response.Entries) != 0 {
		t.Fatalf("scope site filter leaked entries: %#v %v", page, err)
	}
}
