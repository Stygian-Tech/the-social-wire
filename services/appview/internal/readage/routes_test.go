package readage

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestReadAgeRoutesAuthenticateAndValidateBeforeReading(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, test := range []struct{ method, path string }{{"GET", "/xrpc/app.thesocialwire.appview.getReadAgeOptions"}, {"POST", "/xrpc/app.thesocialwire.appview.markReadBefore"}, {"POST", "/v1/appview/mark-all-read"}} {
		for _, did := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
			req := httptest.NewRequest(test.method, test.path, strings.NewReader(`{}`))
			if did != "" {
				req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: did}))
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != 401 {
				t.Fatalf("private route %s returned %d", test.path, w.Code)
			}
		}
	}
	for _, target := range []string{"/xrpc/app.thesocialwire.appview.getReadAgeOptions?kind=subscribed", "/xrpc/app.thesocialwire.appview.getReadAgeOptions?kind=publication&timeZone=UTC", "/xrpc/app.thesocialwire.appview.getReadAgeOptions?kind=subscribed&timeZone=%2B03%3A00"} {
		req := httptest.NewRequest("GET", target, nil)
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer"}))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != 400 {
			t.Fatalf("invalid selection %s returned %d", target, w.Code)
		}
	}
}

func TestPublishedAgeSnapshotMarksOlderLaterRowsAndPreservesCommittedSuccess(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	viewer := fmt.Sprintf("did:plc:readage-route%d", time.Now().UnixNano())
	author := viewer + "-author"
	now := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		db.Exec(`DELETE FROM read_marks WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer)
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	ids := []string{}
	for i, published := range []time.Time{now, now.Add(-10 * 24 * time.Hour)} {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		ids = append(ids, uri)
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(context.Background(), thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: now.Add(-time.Duration(i) * time.Second), IndexedAt: now, ExpiresAt: now.Add(time.Hour), Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: published.Format(time.RFC3339)}}); err != nil {
			t.Fatal(err)
		}
	}
	invalidations := 0
	routes := Routes{DB: db, Now: func() time.Time { return now }, ResolveScopes: func(context.Context, gatewaycore.AuthContext, appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error) {
		return []appviewcore.PublicationScope{{PublicationID: author, AuthorDID: author}}, nil
	}, RefreshCounts: func(context.Context, string, []appviewcore.PublicationScope, time.Time) (map[string]int, error) {
		return nil, fmt.Errorf("recount fixture failure")
	}, Invalidate: func(context.Context, string, []string) error {
		invalidations++
		return fmt.Errorf("cache fixture failure")
	}}
	mux := http.NewServeMux()
	routes.Register(mux)
	req := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.appview.getReadAgeOptions?kind=subscribed&timeZone=UTC", nil)
	req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: viewer}))
	req.Header.Set("Accept", "application/x-ndjson")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/x-ndjson" || !strings.Contains(w.Body.String(), `"days":7`) || !strings.Contains(w.Body.String(), `"type":"done"`) {
		t.Fatalf("age stream: %d %s", w.Code, w.Body.String())
	}
	body := fmt.Sprintf(`{"scope":{"kind":"subscribed"},"before":%q}`, now.Add(-24*time.Hour).Format(time.RFC3339))
	req = httptest.NewRequest("POST", "/xrpc/app.thesocialwire.appview.markReadBefore", strings.NewReader(body))
	req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: viewer}))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	var result struct {
		Marked   int            `json:"marked"`
		EntryIDs []string       `json:"entryIds"`
		Counts   map[string]int `json:"unreadCounts"`
	}
	json.Unmarshal(w.Body.Bytes(), &result)
	if w.Code != 200 || result.Marked != 1 || len(result.EntryIDs) != 1 || result.EntryIDs[0] != ids[1] || len(result.Counts) != 0 || invalidations != 1 {
		t.Fatalf("committed response lost after refresh failure: %d %s", w.Code, w.Body.String())
	}
	var read bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)`, viewer, ids[1]).Scan(&read); err != nil || !read {
		t.Fatalf("older later entry unmarked: %v %v", read, err)
	}
}
