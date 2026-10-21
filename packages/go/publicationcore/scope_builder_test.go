package publicationcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"slices"
	"testing"
	"time"
)

type repoFixture struct {
	records map[string]gatewaycore.RepoRecord
	pages   map[string][]gatewaycore.RepoRecord
}

func (r repoFixture) GetRecord(_ context.Context, did, col, key, cid string) (*gatewaycore.RepoRecord, error) {
	v, ok := r.records["at://"+did+"/"+col+"/"+key]
	if !ok {
		return nil, nil
	}
	return &v, nil
}
func (r repoFixture) ListRecords(_ context.Context, did, col, cursor string, limit int, reverse bool) (gatewaycore.RepoPage, error) {
	return gatewaycore.RepoPage{Records: r.pages[did+"/"+col]}, nil
}
func (r repoFixture) ResolvePDS(context.Context, string) (string, error) {
	return "https://pds.invalid", nil
}
func (r repoFixture) ResolveDID(_ context.Context, did string) (string, error) { return did, nil }
func record(uri string, value map[string]any) gatewaycore.RepoRecord {
	raw, _ := json.Marshal(value)
	v := map[string]json.RawMessage{}
	json.Unmarshal(raw, &v)
	return gatewaycore.RepoRecord{URI: uri, Value: v}
}
func TestScopeSiblingSiteAndRSS(t *testing.T) {
	author := "did:plc:author"
	uri := "at://" + author + "/site.standard.publication/a"
	sibling := "at://" + author + "/app.offprint.publication/b"
	repo := repoFixture{records: map[string]gatewaycore.RepoRecord{uri: record(uri, map[string]any{"site": "https://site.invalid/?q=1", "url": "https://site.invalid/blog/"})}, pages: map[string][]gatewaycore.RepoRecord{author + "/app.offprint.publication": {record(sibling, map[string]any{"site": "https://site.invalid", "homepage": "https://site.invalid/articles"}), record("at://"+author+"/app.offprint.publication/c", map[string]any{"site": "https://unrelated.invalid"})}}}
	scope := BuildScope(context.Background(), repo, uri, author)
	contains := func(values []string, want string) bool {
		for _, v := range values {
			if v == want {
				return true
			}
		}
		return false
	}
	if !contains(scope.PublicationScopeATURIs, sibling) || !contains(scope.PublicationSiteURLs, "https://site.invalid/articles") || contains(scope.PublicationSiteURLs, "https://unrelated.invalid") {
		t.Fatalf("sibling scope %+v", scope)
	}
	rss := BuildScope(context.Background(), repo, thinappviewcore.RSSPublicationID("https://feed.invalid/rss"), "")
	if rss.AuthorDID != thinappviewcore.RSSAuthorDID || len(rss.PublicationSiteURLs) != 1 || rss.PublicationATURI != nil {
		t.Fatalf("RSS scope %+v", rss)
	}
}

// The primary record and CID remain unchanged while sibling membership changes.
// Every manual refresh must reread sibling pages, even on the same Service.
func TestScopeSiblingSiteAndRSSRefreshCoalescesPages(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:sibling-refresh%d", time.Now().UnixNano())
	author := "did:plc:author"
	fixture := refreshFixture(3)
	fixture.pages[viewer+"/site.standard.graph.subscription"] = fixture.pages["viewer/site.standard.graph.subscription"]
	delete(fixture.pages, "viewer/site.standard.graph.subscription")
	for id := range fixture.records {
		r := record(id, map[string]any{"title": "Same Site", "site": "https://site.invalid"})
		r.CID = "unchanged-primary"
		fixture.records[id] = r
	}
	sibling := "at://" + author + "/app.offprint.publication/sibling"
	unrelated := "at://" + author + "/app.offprint.publication/unrelated"
	fixture.pages[author+"/app.offprint.publication"] = []gatewaycore.RepoRecord{
		record(sibling, map[string]any{"site": "https://site.invalid", "homepage": "https://site.invalid/old"}),
		record(unrelated, map[string]any{"site": "https://unrelated.invalid"}),
	}
	r := &refreshLookupRepo{repoFixture: fixture}
	s := NewService(db, r, nil)
	defer s.Close()
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	for refresh := 0; refresh < 2; refresh++ {
		want := "https://site.invalid/old"
		if refresh == 1 {
			want = "https://site.invalid/new"
			fixture.pages[author+"/app.offprint.publication"] = []gatewaycore.RepoRecord{
				record(sibling, map[string]any{"site": "https://site.invalid", "homepage": want}),
				record(unrelated, map[string]any{"site": "https://unrelated.invalid"}),
			}
		}
		result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
		if err != nil {
			t.Fatal(err)
		}
		if len(result.AllPublicationRows) != 3 {
			t.Fatalf("rows=%d", len(result.AllPublicationRows))
		}
		for _, row := range result.AllPublicationRows {
			scope := row.AppViewScope
			if !slices.Contains(scope.PublicationScopeATURIs, sibling) || slices.Contains(scope.PublicationScopeATURIs, unrelated) || !slices.Contains(scope.PublicationSiteURLs, want) || slices.Contains(scope.PublicationSiteURLs, "https://unrelated.invalid") {
				t.Fatalf("refresh %d incorrect scope: %+v", refresh, scope)
			}
			if refresh == 1 && slices.Contains(scope.PublicationSiteURLs, "https://site.invalid/old") {
				t.Fatal("old sibling metadata survived")
			}
		}
		// One author page per collection, plus the viewer's own discovery probe.
		for _, col := range publicationCollections {
			if got := r.lists[col]; got != 2*(refresh+1) {
				t.Fatalf("refresh %d %s reads=%d", refresh, col, got)
			}
		}
		if r.gets != 3*(refresh+1) {
			t.Fatalf("refresh %d gets=%d", refresh, r.gets)
		}
		if s.Repo != r || s.discoveries[viewer].value.refresh != nil {
			t.Fatal("refresh metadata escaped its request")
		}
	}
}
