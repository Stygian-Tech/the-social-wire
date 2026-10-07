package thinappviewcore

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCounterPreservesReadFloorOverridesAndPDSAuthority(t *testing.T) {
	db := inboxDatabase(t)
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	did := "did:plc:" + nonce
	viewer := "did:plc:viewer" + nonce
	pub := "pub-" + nonce
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_unread_counters WHERE viewer_did=$1", viewer)
		db.Exec("DELETE FROM appview_publication_scopes WHERE viewer_did=$1", viewer)
		db.Exec("DELETE FROM appview_publication_read_floors WHERE viewer_did=$1", viewer)
		db.Exec("DELETE FROM appview_unread_overrides WHERE viewer_did=$1", viewer)
	})
	if _, err = db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did)VALUES($1,$2,$3)`, viewer, pub, did); err != nil {
		t.Fatal(err)
	}
	uri := "at://" + did + "/site.standard.document/fixture"
	if _, err = db.Exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,read_floor_uri,generation)VALUES($1,$2,$3,$4,1)`, viewer, pub, at, uri); err != nil {
		t.Fatal(err)
	}
	store := CounterStore{DB: db}
	item := IndexedContentItem{URI: uri, AuthorDID: did, CreatedAt: at}
	if err = store.Increment(ctx, item, at); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = db.QueryRow("SELECT count(*) FROM appview_unread_counters WHERE viewer_did=$1", viewer).Scan(&count); err != nil || count != 0 {
		t.Fatalf("floor did not contain tie %d %v", count, err)
	}
	if _, err = db.Exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at)VALUES($1,$2,$3)`, viewer, uri, at); err != nil {
		t.Fatal(err)
	}
	if err = store.Increment(ctx, item, at); err != nil {
		t.Fatal(err)
	}
	store.PDSAuthority = func(context.Context, string) (bool, error) { return true, nil }
	store.PDSIsRead = func(context.Context, string, string) (bool, error) { return true, nil }
	if err = store.Increment(ctx, item, at); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow("SELECT unread_count FROM appview_unread_counters WHERE viewer_did=$1", viewer).Scan(&count); err != nil || count != 1 {
		t.Fatalf("PDS read override ignored %d %v", count, err)
	}
	store.PDSIsRead = func(context.Context, string, string) (bool, error) { return false, errors.New("cache evicted") }
	if err = store.Increment(ctx, item, at); err == nil {
		t.Fatal("failed-open PDS read authority")
	}
}
