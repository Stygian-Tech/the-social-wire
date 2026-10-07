package thinappviewcore

import (
	"context"
	"testing"
	"time"
)

func TestPostgresContentRecoveryPreservesConcurrentUpdates(t *testing.T) {
	db := inboxDatabase(t)
	ctx := context.Background()
	store := ContentStore{DB: db}
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	did := "did:plc:content" + nonce
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() { db.Exec("DELETE FROM content_items WHERE author_did=$1", did) })
	for _, suffix := range []string{"missing", "seen", "concurrent"} {
		indexed := at
		if suffix == "concurrent" {
			indexed = at.Add(time.Second)
		}
		item := IndexedContentItem{URI: "at://" + did + "/site.standard.document/" + suffix, CID: "fixture", AuthorDID: did, Collection: "site.standard.document", CreatedAt: at, IndexedAt: indexed, ExpiresAt: at.Add(time.Hour), Render: ContentRenderFields{Title: suffix, PublishedAt: at.Format(time.RFC3339)}}
		if err := store.Upsert(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	seen := "at://" + did + "/site.standard.document/seen"
	deleted, err := store.DeleteMissingAuthorRecords(ctx, did, []string{seen}, at)
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 1 {
		t.Fatalf("pruned %d records", deleted)
	}
	for _, suffix := range []string{"seen", "concurrent"} {
		found, err := store.Exists(ctx, "at://"+did+"/site.standard.document/"+suffix)
		if err != nil || !found {
			t.Fatalf("lost %s record: %v", suffix, err)
		}
	}
}
