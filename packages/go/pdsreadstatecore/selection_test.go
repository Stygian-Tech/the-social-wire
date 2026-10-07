package pdsreadstatecore

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestPreparedBoundaryKeepsWatermarkAndPreviewRespectsPublication(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_READSTATE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:selection%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication, other := "https://example.invalid/one", "https://example.invalid/two"
	at := time.Now().UTC().Truncate(time.Millisecond)
	t.Cleanup(func() {
		db.Exec(`DELETE FROM appview_publication_read_floors WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	subjects := []string{}
	for i, site := range []string{publication, other} {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		subjects = append(subjects, uri)
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at.Add(-time.Hour), IndexedAt: at, ExpiresAt: at.Add(-time.Minute), PublicationSite: &site, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,read_floor_uri,generation) VALUES($1,$2,$3,NULL,1)`, viewer, publication, at); err != nil {
		t.Fatal(err)
	}
	store := Store{DB: db}
	boundaries, err := store.PrepareBoundaries(ctx, viewer, []r.Scope{{PublicationID: publication, AuthorDID: author, PublicationSiteKeys: []string{publication}}}, at)
	if err != nil || len(boundaries) != 1 || boundaries[0].EntryID != nil || boundaries[0].CreatedAt != at.Format("2006-01-02T15:04:05.000Z") {
		t.Fatalf("watermark regressed: %#v %v", boundaries, err)
	}
	matched, err := store.PreviewBoundaries(ctx, boundaries, append(subjects, subjects[0]))
	if err != nil || len(matched) != 1 || matched[0] != subjects[0] {
		t.Fatalf("preview leaked publication/duplicated subject: %v %v", matched, err)
	}
	if _, err := db.Exec(`DELETE FROM appview_publication_read_floors WHERE viewer_did=$1`, viewer); err != nil {
		t.Fatal(err)
	}
	boundaries, err = store.PrepareBoundaries(ctx, viewer, []r.Scope{{PublicationID: publication, AuthorDID: author, PublicationSiteKeys: []string{publication}}}, at)
	if err != nil || len(boundaries) != 1 || boundaries[0].EntryID == nil || *boundaries[0].EntryID != subjects[0] {
		t.Fatalf("expired indexed boundary omitted: %#v %v", boundaries, err)
	}
}
