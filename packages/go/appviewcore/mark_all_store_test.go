package appviewcore

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestMarkAllPreservesNewerUnreadOverridesAndRejectsPDSWrites(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:markall%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/a"
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		db.Exec(`UPDATE appview_pds_read_state_authority SET manifest=NULL,manifest_cid=NULL WHERE viewer_did=$1`, viewer)
		for _, table := range []string{"appview_unread_overrides", "appview_publication_read_floors", "appview_unread_counters"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	ids := []string{}
	for i, position := range []time.Time{at.Add(-2 * time.Second), at.Add(-time.Second), at.Add(5 * time.Second)} {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		ids = append(ids, uri)
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: position, IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &publication, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339Nano)}}); err != nil {
			t.Fatal(err)
		}
	}
	for _, override := range []struct {
		uri     string
		created time.Time
	}{{ids[0], at.Add(-time.Second)}, {ids[1], at.Add(time.Second)}, {"rssentry:orphan", at.Add(-time.Second)}} {
		if _, err := db.Exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, override.uri, override.created); err != nil {
			t.Fatal(err)
		}
	}
	scope := PublicationScope{PublicationID: publication, AuthorDID: author, PublicationATURI: &publication}
	store := ReadMutationStore{DB: db}
	result, err := store.MarkAll(ctx, viewer, []PublicationScope{scope, scope}, at)
	if err != nil || len(result.Counters) != 1 || result.Counters[0].UnreadCount != 2 || len(result.Boundaries) != 1 || result.Boundaries[0].EntryID == nil || *result.Boundaries[0].EntryID != ids[1] {
		t.Fatalf("markall lost newer override/entry: %#v %v", result, err)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM appview_unread_overrides WHERE viewer_did=$1`, viewer).Scan(&count); err != nil || count != 1 {
		t.Fatalf("override cleanup: %d %v", count, err)
	}
	result, err = store.MarkAll(ctx, viewer, []PublicationScope{scope}, at.Add(2*time.Second))
	if err != nil || result.Counters[0].UnreadCount != 1 {
		t.Fatalf("later action did not clear earlier override: %#v %v", result, err)
	}
	if _, err := db.Exec(`UPDATE appview_pds_read_state_authority SET manifest='{}',manifest_cid='verified-fixture' WHERE viewer_did=$1`, viewer); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MarkAll(ctx, viewer, []PublicationScope{scope}, at); !errors.Is(err, ErrPDSReadStateRequired) {
		t.Fatalf("PDS authority legacy bulk mutation: %v", err)
	}
}
