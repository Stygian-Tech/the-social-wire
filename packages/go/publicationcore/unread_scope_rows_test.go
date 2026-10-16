package publicationcore

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestUnreadIDsUseDurableViewerScopesWithPartialSidebar(t *testing.T) {
	db := fixtureDB(t)
	viewer := fmt.Sprintf("did:plc:durable-unread-%d", time.Now().UnixNano())
	other := viewer + "-other"
	at := time.Now().UTC()
	ids := []string{"at://did:plc:durable/site.standard.publication/a", "at://did:plc:durable/site.standard.publication/b"}
	repo := &canceledUnreadRepo{}
	service := NewService(db, repo, &http.Client{Transport: unreadGraphTransport{}})
	defer service.Close()
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	service.Cache = &cache
	t.Cleanup(func() {
		cache.InvalidateSidebar(context.Background(), viewer)
		for _, table := range []string{"appview_publication_scopes", "appview_unread_counters", "unread_counts_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=ANY($1::text[])", []string{viewer, other})
		}
	})
	for i, id := range ids {
		if _, err := db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,updated_at) VALUES($1,$2,'did:plc:durable',$2,$3)`, viewer, id, at); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,$3,1,'exact',FALSE,$4)`, viewer, id, i+3, at); err != nil {
			t.Fatal(err)
		}
	}
	partial := Sidebar{ViewerDID: viewer, AllPublicationRows: []SidebarRow{{PublicationID: ids[0], AppViewScope: AppViewScope{AuthorDID: "did:plc:durable", PublicationATURI: &ids[0]}}}}
	if err := cache.Store(context.Background(), viewer, BootstrapSnapshot{Version: 1, Priority: partial}, at); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	out, err := service.UnreadCountsByPublicationIDs(ctx, gatewaycore.AuthContext{DID: viewer}, []string{ids[0], url.QueryEscape(ids[1])})
	if err != nil || out.Counts[ids[0]] != 3 || out.Counts[ids[1]] != 4 || repo.calls.Load() != 0 {
		t.Fatalf("durable scope lookup invoked discovery or changed counts: %+v error=%v calls=%d", out, err, repo.calls.Load())
	}
	// A scope belonging to another viewer cannot turn an unknown publication
	// into an authorized durable hit. Genuine misses retain live discovery.
	unknown := "at://did:plc:durable/site.standard.publication/private"
	if _, err := db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,updated_at) VALUES($1,$2,'did:plc:durable',$3)`, other, unknown, at); err != nil {
		t.Fatal(err)
	}
	rows, err := service.unreadScopeRows(ctx, viewer, []string{unknown})
	if err != nil || len(rows) != 0 {
		t.Fatalf("other viewer scope leaked: %+v %v", rows, err)
	}
	unknownCtx, stop := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer stop()
	if _, err := service.UnreadCountsByPublicationIDs(unknownCtx, gatewaycore.AuthContext{DID: viewer}, []string{unknown}); err == nil || repo.calls.Load() == 0 || repo.active.Load() != 0 {
		t.Fatalf("unknown ID must retain bounded discovery: error=%v calls=%d active=%d", err, repo.calls.Load(), repo.active.Load())
	}
}
