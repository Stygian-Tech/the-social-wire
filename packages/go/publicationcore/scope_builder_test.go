package publicationcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
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
