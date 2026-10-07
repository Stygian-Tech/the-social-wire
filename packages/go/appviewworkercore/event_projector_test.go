package appviewworkercore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

func TestProjectorContentLifecycleAndIdempotentCounter(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	did := "did:plc:" + nonce
	viewer := "did:plc:viewer" + nonce
	site := "https://publisher.social/" + nonce
	pub := "publication-" + nonce
	key := "fixture"
	uri := "at://" + did + "/site.standard.document/" + key
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		db.Exec("DELETE FROM content_items WHERE author_did=$1", did)
		db.Exec("DELETE FROM appview_unread_counters WHERE viewer_did=$1", viewer)
		db.Exec("DELETE FROM appview_publication_scopes WHERE viewer_did=$1", viewer)
	})
	_, err = db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_site_urls,scope_keys)VALUES($1,$2,$3,$4::jsonb,$4::jsonb)`, viewer, pub, did, `["`+site+`"]`)
	if err != nil {
		t.Fatal(err)
	}
	p := EventProjectorRuntime{DB: db, Counters: thinappviewcore.CounterStore{DB: db}, Now: func() time.Time { return at }}
	raw, _ := json.Marshal(map[string]any{"title": "Original", "site": site, "publishedAt": at.Format(time.RFC3339Nano), "content": "<p>Body</p>", "url": site + "/entry"})
	for i := 0; i < 2; i++ {
		if err := p.Commit(ctx, did, "site.standard.document", key, "cid", "create", "rev", raw, at, ""); err != nil {
			t.Fatal(err)
		}
	}
	var count int
	var dirty bool
	if err := db.QueryRow("SELECT unread_count,dirty FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2", viewer, pub).Scan(&count, &dirty); err != nil {
		t.Fatal(err)
	}
	if count != 1 || !dirty {
		t.Fatalf("counter replay %d %v", count, dirty)
	}
	if err := p.Commit(ctx, did, "site.standard.document", key, "", "delete", "rev2", nil, at, ""); err != nil {
		t.Fatal(err)
	}
	exists, err := (thinappviewcore.ContentStore{DB: db}).Exists(ctx, uri)
	if err != nil || exists {
		t.Fatalf("content survived delete %v %v", exists, err)
	}
}
