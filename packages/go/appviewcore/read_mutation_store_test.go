package appviewcore

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestConcurrentReadMutationsAdjustCounterOnceAndFencePDSAuthority(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:read-mutation-%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/a"
	subject := "at://" + author + "/site.standard.document/a"
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		db.Exec(`UPDATE appview_pds_read_state_authority SET manifest=NULL,manifest_cid=NULL WHERE viewer_did=$1`, viewer)
		for _, table := range []string{"appview_pds_read_state_exact", "appview_pds_read_state_boundaries", "read_marks", "appview_unread_overrides", "appview_unread_counters", "appview_publication_scopes", "unread_counts_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM content_items WHERE uri=$1`, subject)
	})
	item := thinappviewcore.IndexedContentItem{URI: subject, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at, IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &publication, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}
	if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`, viewer, publication, author, at); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,1,1,'exact',FALSE,$3)`, viewer, publication, at); err != nil {
		t.Fatal(err)
	}
	store := ReadMutationStore{DB: db}
	for _, read := range []bool{true, false, true} {
		var wg sync.WaitGroup
		errs := make(chan error, 8)
		for range 8 {
			wg.Add(1)
			go func() { defer wg.Done(); errs <- store.Put(ctx, viewer, subject, read, at) }()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				t.Fatal(err)
			}
		}
		var count int
		if err := db.QueryRow(`SELECT unread_count FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2`, viewer, publication).Scan(&count); err != nil {
			t.Fatal(err)
		}
		want := 1
		if read {
			want = 0
		}
		if count != want {
			t.Fatalf("read=%v count=%d want=%d", read, count, want)
		}
	}
	if _, err := db.Exec(`UPDATE appview_pds_read_state_authority SET manifest='{}',manifest_cid='verified-fixture' WHERE viewer_did=$1`, viewer); err != nil {
		t.Fatal(err)
	}
	if err := store.Put(ctx, viewer, subject, false, at); !errors.Is(err, ErrPDSReadStateRequired) {
		t.Fatalf("legacy write after activation: %v", err)
	}
	states, err := (ReadStateStore{DB: db}).ReadStates(ctx, viewer, []Entry{{EntryID: subject, PublicationID: &publication, FeedPositionAt: at}})
	if err != nil || states[subject] {
		t.Fatalf("empty authoritative PDS generation inherited legacy read: %v %v", states, err)
	}
}
