package thinappviewcore

import (
	"testing"
	"time"
)

func TestRenderFieldsFallbackAndPublisherEntities(t *testing.T) {
	at := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	fields := ExtractRenderFields(map[string]any{"name": "<b>A &AMP; B &unknown;</b>", "description": "&ndash; &#x1F600;", "path": "/notes/first/"}, "", "", at)
	if fields.Title != "A & B &unknown;" || fields.Summary == nil || *fields.Summary != "– 😀" || fields.PublishedAt != "2026-10-07T00:00:00Z" {
		t.Fatalf("render: %+v", fields)
	}
	slug := ExtractRenderFields(map[string]any{"path": "/notes/first/"}, "", "", at)
	if slug.Title != "first" {
		t.Fatal(slug.Title)
	}
}
func TestRenderArticleAndBlobAuthority(t *testing.T) {
	record := map[string]any{"site": map[string]any{"uri": "at://did:plc:author/site.standard.publication/main"}, "path": "/notes/first"}
	if ArticleURL(record, "") != "" {
		t.Fatal("AT-URI publication must be resolved before article URL construction")
	}
	if ArticleURL(record, "http://publisher.example/base/?ignored=1#fragment") != "https://publisher.example/base/notes/first" {
		t.Fatal("resolved article URL")
	}
	record["canonicalUrl"] = "http://publisher.example/article?query=1#fragment"
	if ArticleURL(record, "") != "https://publisher.example/article?query=1" {
		t.Fatal("article query must survive normalization")
	}
	if BuildSyncGetBlobURL("https://atproto.brid.gy", "did:plc:author", "cid") != "" {
		t.Fatal("Bridgy blobs must not be selected")
	}
	if BuildSyncGetBlobURL("https://sub.brid.gy", "did:plc:author", "cid") != "" {
		t.Fatal("Bridgy subdomain blobs must not be selected")
	}
	fields := ExtractRenderFields(map[string]any{"coverImage": map[string]any{"ref": map[string]any{"$link": "bafycid"}}}, "did:plc:author", "https://pds.example/", time.Now())
	if fields.ThumbnailURL == nil || *fields.ThumbnailURL != "https://pds.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Aauthor&cid=bafycid" {
		t.Fatalf("blob URL %+v", fields)
	}
}

func TestPublicationScopeDoesNotCollapseFeedQueries(t *testing.T) {
	if MatchesPublication("https://publisher.example/feed?edition=other", "", nil, []string{"https://publisher.example/feed?edition=selected"}) {
		t.Fatal("different feeds must retain query identity")
	}
	if !MatchesPublication("at://DID:PLC:Author/com.standard.publication/main", "at://did:plc:author/site.standard.publication/main", nil, nil) {
		t.Fatal("publication AT-URI aliases")
	}
	if MatchesPublication("at://did:plc:author/site.standard.publication/other", "at://did:plc:author/site.standard.publication/main", nil, nil) {
		t.Fatal("publication rkey scope")
	}
}
