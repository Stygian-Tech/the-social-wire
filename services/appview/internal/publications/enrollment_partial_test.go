package publications

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestPartialEnrollmentPublishesCommittedUnreadCounts(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("canonical PostgreSQL fixture required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:partialenroll%d", time.Now().UnixNano())
	feed := "https://" + strings.TrimPrefix(viewer, "did:plc:") + ".invalid/rss"
	id := "rss-fixture"
	at := time.Now().UTC()
	uri := "at://" + thinappviewcore.RSSAuthorDID + "/site.standard.document/" + viewer
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes", "appview_unread_counters", "unread_counts_cache", "sidebar_projection_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE uri=$1", uri)
	})
	row := publicationcore.SidebarRow{PublicationID: id, AuthorDID: thinappviewcore.RSSAuthorDID, AppViewScope: publicationcore.AppViewScope{AuthorDID: thinappviewcore.RSSAuthorDID, PublicationSiteURLs: []string{feed}}}
	if err := (publicationcore.ProjectionStore{DB: db}).Persist(ctx, publicationcore.Sidebar{ViewerDID: viewer, AllPublicationRows: []publicationcore.SidebarRow{row}}, true); err != nil {
		t.Fatal(err)
	}
	// Represents a source committed before another source fails in the same request.
	if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: thinappviewcore.RSSAuthorDID, Collection: "site.standard.document", CreatedAt: at, IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &feed, Render: thinappviewcore.ContentRenderFields{Title: "Committed Article", PublishedAt: at.Format(time.RFC3339)}}); err != nil {
		t.Fatal(err)
	}
	service := publicationcore.NewService(db, nil, nil)
	defer service.Close()
	service.Cache = &publicationcore.CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	service.Enroller = &publicationcore.Enroller{}
	mux := http.NewServeMux()
	(Routes{Service: service}).Register(mux)
	for _, path := range []string{"/v1/appview/enroll", "/xrpc/app.thesocialwire.appview.enrollSources"} {
		if _, err := db.Exec("DELETE FROM appview_unread_counters WHERE viewer_did=$1", viewer); err != nil {
			t.Fatal(err)
		}
		body := fmt.Sprintf(`{"authorDids":["invalid-author"],"feedUrls":[%q]}`, feed)
		req := httptest.NewRequest("POST", path, strings.NewReader(body))
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: viewer}))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "Enrollment unavailable") {
			t.Fatalf("partial failure reported incorrectly: %d %s", w.Code, w.Body.String())
		}
		var count int
		if err := db.QueryRow("SELECT unread_count FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2", viewer, id).Scan(&count); err != nil || count != 1 {
			t.Fatalf("committed source count=%d err=%v", count, err)
		}
	}
}
