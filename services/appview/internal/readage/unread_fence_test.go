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

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
)

func TestAgeReadResponseOmitsNewerUnreadAndRecountsCommittedState(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	viewer := fmt.Sprintf("did:plc:age-fence-%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/main"
	protected := "at://" + author + "/site.standard.document/protected"
	eligible := "at://" + author + "/site.standard.document/eligible"
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_unread_counters", "unread_counts_cache", "appview_publication_scopes", "appview_pds_read_state_authority"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	execute := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	for _, subject := range []string{protected, eligible} {
		execute(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at)
 VALUES($1,'fixture',$2,'site.standard.document',$3::timestamptz-interval '10 days',$3,$4,jsonb_build_object('title','Article','publishedAt',$5::text),$3::timestamptz+interval '1 hour')`, subject, author, at, publication, at.Add(-10*24*time.Hour).Format(time.RFC3339))
	}
	execute(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`, viewer, publication, author, at)
	execute(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,2,1,'exact',FALSE,$3)`, viewer, publication, at)
	scope := appviewcore.PublicationScope{PublicationID: publication, AuthorDID: author, PublicationATURI: &publication}
	clockCalls := 0
	routes := Routes{
		DB: db, Now: func() time.Time {
			clockCalls++
			if clockCalls%2 == 1 {
				return at
			}
			return at.Add(2 * time.Second)
		},
		ResolveScopes: func(ctx context.Context, _ gatewaycore.AuthContext, _ appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error) {
			// The action timestamp is frozen before scope resolution. Another
			// client's explicit unread commits while that age action is pending.
			if err := (appviewcore.ReadMutationStore{DB: db}).Put(ctx, viewer, protected, false, at.Add(time.Second)); err != nil {
				return nil, err
			}
			return []appviewcore.PublicationScope{scope}, nil
		},
		RefreshCounts: func(ctx context.Context, viewer string, scopes []appviewcore.PublicationScope, countedAt time.Time) (map[string]int, error) {
			snapshot, err := (publicationcore.CounterStore{DB: db}).Refresh(ctx, viewer, scopes, countedAt)
			return snapshot.Counts, err
		},
	}
	mux := http.NewServeMux()
	routes.Register(mux)
	for attempt := 0; attempt < 2; attempt++ {
		body := fmt.Sprintf(`{"scope":{"kind":"subscribed"},"before":%q}`, at.Add(-24*time.Hour).Format(time.RFC3339))
		req := httptest.NewRequest("POST", "/xrpc/app.thesocialwire.appview.markReadBefore", strings.NewReader(body))
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: viewer}))
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, req)
		var result struct {
			Marked int            `json:"marked"`
			IDs    []string       `json:"entryIds"`
			Counts map[string]int `json:"unreadCounts"`
			ReadAt string         `json:"readAt"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || response.Code != 200 {
			t.Fatalf("response: status=%d error=%v body=%s", response.Code, err, response.Body.String())
		}
		wantMarked := 1 - attempt
		if result.Marked != wantMarked || len(result.IDs) != wantMarked || result.Counts[publication] != 1 || (wantMarked == 1 && result.IDs[0] != eligible) {
			t.Fatalf("age/replay confirmation included fenced state: %#v", result)
		}
		readAt, parseErr := time.Parse(time.RFC3339Nano, result.ReadAt)
		if parseErr != nil || !readAt.Equal(at) {
			t.Fatalf("action timestamp changed during recount: %s", result.ReadAt)
		}
		var count int
		var generation int64
		var countedAt time.Time
		var dirty bool
		if err := db.QueryRow(`SELECT unread_count,generation,counted_at,dirty FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2`, viewer, publication).Scan(&count, &generation, &countedAt, &dirty); err != nil || count != 1 || generation < at.Add(time.Second).UnixMilli() || !countedAt.Equal(at.Add(2*time.Second)) || dirty {
			t.Fatalf("recount backdated newer intent: count=%d generation=%d countedAt=%s dirty=%v error=%v", count, generation, countedAt, dirty, err)
		}
		var protectedUnread, protectedRead bool
		if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=$2),EXISTS(SELECT 1 FROM read_marks WHERE viewer_did=$1 AND subject_uri=$2)`, viewer, protected).Scan(&protectedUnread, &protectedRead); err != nil || !protectedUnread || protectedRead {
			t.Fatalf("newer explicit unread did not survive: unread=%v read=%v error=%v", protectedUnread, protectedRead, err)
		}
	}
}
