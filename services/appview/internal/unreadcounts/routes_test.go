package unreadcounts

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"
)

func TestRouteAuthenticationAndCommaLists(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, path := range []string{"/v1/appview/unread-counts", "/xrpc/app.thesocialwire.appview.getUnreadCounts"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 401 {
			t.Fatal(w.Code)
		}
	}
	if n := len(split(" a, ,b,c ")); n != 3 {
		t.Fatal(n)
	}
}
func TestUnreadRouteLegacyAndRepeatedPublicationIDs(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("canonical PostgreSQL fixture required")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	ctx := context.Background()
	at := time.Now().UTC()
	viewer := fmt.Sprintf("did:plc:unreadroute%d", at.UnixNano())
	pub := "at://did:plc:author/site.standard.publication/a"
	service := publicationcore.NewService(db, nil, nil)
	defer service.Close()
	cache := publicationcore.CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	service.Cache = &cache
	sidebar := publicationcore.Sidebar{ViewerDID: viewer, RefreshedAt: at, AllPublicationRows: []publicationcore.SidebarRow{{PublicationID: pub, AppViewScope: publicationcore.AppViewScope{AuthorDID: "did:plc:author", PublicationATURI: &pub}, DiscoveredAt: at}}}
	if e := cache.Store(ctx, viewer, publicationcore.BootstrapSnapshot{Version: 1, Priority: sidebar}, at); e != nil {
		t.Fatal(e)
	}
	if _, e := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)VALUES($1,$2,4,42,'exact',false,$3)`, viewer, pub, at); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		cache.InvalidateSidebar(ctx, viewer)
		for _, table := range []string{"appview_unread_counters", "unread_counts_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	mux := http.NewServeMux()
	Routes{DB: db, Publications: service}.Register(mux)
	for _, path := range []string{"/v1/appview/unread-counts?publicationIds=" + url.QueryEscape(pub) + ",%20&publicationIds=" + url.QueryEscape(pub), "/xrpc/app.thesocialwire.appview.getUnreadCounts?publicationIds=" + url.QueryEscape(pub)} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", path, nil)
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: viewer}))
		mux.ServeHTTP(w, r)
		var out struct {
			Counts   map[string]int
			Accuracy string
		}
		if json.Unmarshal(w.Body.Bytes(), &out) != nil || w.Code != 200 || out.Counts[pub] != 4 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/v1/appview/unread-counts?publicationIds=,,&publicationAtUri=", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: viewer}))
	mux.ServeHTTP(w, r)
	var legacy map[string]json.RawMessage
	json.Unmarshal(w.Body.Bytes(), &legacy)
	if w.Code != 200 || len(legacy) != 1 || string(legacy["counts"]) != `{"":0}` {
		t.Fatal(w.Code, w.Body.String())
	}
}
