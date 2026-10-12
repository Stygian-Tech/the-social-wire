package analyticscore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type repoFixture struct {
	pages   map[string]gatewaycore.RepoPage
	records map[string]*gatewaycore.RepoRecord
}

func (r repoFixture) ListRecords(_ context.Context, _, collection, cursor string, _ int, _ bool) (gatewaycore.RepoPage, error) {
	if cursor != "" {
		return gatewaycore.RepoPage{}, nil
	}
	return r.pages[collection], nil
}
func (r repoFixture) GetRecord(_ context.Context, d, c, k, _ string) (*gatewaycore.RepoRecord, error) {
	return r.records["at://"+d+"/"+c+"/"+k], nil
}

type transport func(*http.Request) (*http.Response, error)

func (t transport) RoundTrip(r *http.Request) (*http.Response, error) { return t(r) }
func record(uri, kind string, fields map[string]string) gatewaycore.RepoRecord {
	v := map[string]json.RawMessage{}
	fields["$type"] = kind
	for k, s := range fields {
		raw, _ := json.Marshal(s)
		v[k] = raw
	}
	return gatewaycore.RepoRecord{URI: uri, Value: v}
}
func TestInventoryKeepsUnavailableCountersUnknownAndRejectsMismatchedAuthors(t *testing.T) {
	uri := "at://did:plc:a/app.bsky.feed.post/one"
	repo := repoFixture{pages: map[string]gatewaycore.RepoPage{"app.bsky.feed.post": {Records: []gatewaycore.RepoRecord{record(uri, "app.bsky.feed.post", map[string]string{"text": "Hello"})}, Cursor: "more"}}}
	body := `{"posts":[{"uri":"` + uri + `","author":{"did":"did:plc:a"},"likeCount":3,"replyCount":1,"repostCount":2,"quoteCount":4}]}`
	client := &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "" {
			t.Fatal("public request leaked credentials")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	p := Provider{Repo: repo, HTTP: client, AppView: "https://api.bsky.app"}
	items, complete, e := p.Inventory(context.Background(), "did:plc:a", time.Now())
	if e != nil || !complete || items[0].Engagement.Likes != 3 {
		t.Fatal(items, complete, e)
	}
	body = `{"posts":[{"uri":"` + uri + `","author":{"did":"did:plc:a"},"likeCount":3}]}`
	items, _, e = p.Inventory(context.Background(), "did:plc:a", time.Now())
	if e != nil || items[0].Engagement != nil {
		t.Fatal("missing counters became zero", items, e)
	}
	body = strings.Replace(body, `"did":"did:plc:a"`, `"did":"did:plc:other"`, 1)
	if _, _, e = p.Inventory(context.Background(), "did:plc:a", time.Now()); e == nil {
		t.Fatal("accepted another author")
	}
}
func TestCanonicalSubjectValidationAndCTR(t *testing.T) {
	for _, uri := range []string{"https://example.com", "at://did:plc:a/app.bsky.feed.post/one?x=y", "at://did:plc:a/app.bsky.feed.like/one", "at://did:plc:a/app.bsky.feed.post/one/two"} {
		if _, _, _, e := Subject(uri); e == nil {
			t.Fatal(uri)
		}
	}
	uri := "at://did:plc:a/site.standard.document/one"
	r := record(uri, "site.standard.document", map[string]string{})
	p := Provider{Repo: repoFixture{records: map[string]*gatewaycore.RepoRecord{uri: &r}}}
	if e := p.Validate(context.Background(), uri); e != nil {
		t.Fatal(e)
	}
	r.URI = "at://did:plc:b/site.standard.document/one"
	if e := p.Validate(context.Background(), uri); e == nil {
		t.Fatal("accepted spoofed canonical record")
	}
	v := Tracking{}
	v.CalculateCTR()
	if v.CTR != nil {
		t.Fatal("zero denominator")
	}
	v.Impressions = 4
	v.OutboundClicks = 1
	v.CalculateCTR()
	if *v.CTR != 25 {
		t.Fatal(v)
	}
}

type cursorRepo struct {
	repoFixture
	repeat bool
	calls  int
}

func (r *cursorRepo) ListRecords(_ context.Context, _, collection, cursor string, _ int, reverse bool) (gatewaycore.RepoPage, error) {
	if !reverse {
		return gatewaycore.RepoPage{}, fmt.Errorf("expected latest first")
	}
	if collection == "site.standard.document" {
		return gatewaycore.RepoPage{}, nil
	}
	r.calls++
	next := fmt.Sprint(r.calls)
	if r.repeat {
		next = "same"
	}
	return gatewaycore.RepoPage{Records: []gatewaycore.RepoRecord{record("at://did:plc:a/app.bsky.feed.post/"+fmt.Sprint(r.calls), "app.bsky.feed.post", map[string]string{"text": "Hi"})}, Cursor: next}, nil
}
func TestInventoryPaginationCapAndRepeatedCursor(t *testing.T) {
	r := &cursorRepo{}
	p := Provider{Repo: r, AppView: "https://api.bsky.app", HTTP: &http.Client{Transport: transport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"posts":[]}`))}, nil
	})}}
	items, complete, e := p.Inventory(context.Background(), "did:plc:a", time.Now())
	if e != nil || complete || len(items) != 10 || r.calls != 10 {
		t.Fatal(items, complete, e)
	}
	r.repeat = true
	r.calls = 0
	if _, _, e = p.Inventory(context.Background(), "did:plc:a", time.Now()); e == nil {
		t.Fatal("repeated cursor accepted")
	}
}

func TestArticleInventoryCanonicalPublicationURLAndUnavailableEngagement(t *testing.T) {
	uri := "at://did:plc:a/site.standard.document/article"
	site := "at://did:plc:a/site.standard.publication/blog"
	pub := record(site, "site.standard.publication", map[string]string{"url": "https://publisher.example/blog"})
	repo := repoFixture{pages: map[string]gatewaycore.RepoPage{"site.standard.document": {Records: []gatewaycore.RepoRecord{record(uri, "site.standard.document", map[string]string{"title": "Article", "site": site, "path": "/article", "publishedAt": "2026-10-11T12:00:00Z"})}}}, records: map[string]*gatewaycore.RepoRecord{site: &pub}}
	p := Provider{Repo: repo}
	items, complete, e := p.Inventory(context.Background(), "did:plc:a", time.Now())
	if e != nil || !complete || len(items) != 1 || items[0].Engagement != nil || items[0].URL != "https://publisher.example/blog/article" {
		t.Fatal(items, complete, e)
	}
	for _, invalid := range []string{"https://publisher.example/blog", "at://did:plc:a/site.standard.document/wrong"} {
		if _, _, _, e := publicationSubject(invalid); e == nil {
			t.Fatal("invalid publication accepted")
		}
	}
	repo.pages["site.standard.document"] = gatewaycore.RepoPage{Records: []gatewaycore.RepoRecord{record(uri, "site.standard.document", map[string]string{"title": "Unsafe Link", "site": site, "path": "//evil.example"})}}
	items, _, e = p.Inventory(context.Background(), "did:plc:a", time.Now())
	if e != nil || items[0].URL != "" {
		t.Fatal("accepted absolute article path")
	}
}
func TestEngagementProviderFailuresAndNegativeCounts(t *testing.T) {
	uri := "at://did:plc:a/app.bsky.feed.post/one"
	repo := repoFixture{pages: map[string]gatewaycore.RepoPage{"app.bsky.feed.post": {Records: []gatewaycore.RepoRecord{record(uri, "app.bsky.feed.post", map[string]string{"text": "Hi"})}}}}
	for _, body := range []string{`broken`, strings.Repeat("x", 2*1024*1024+1), `{"posts":[{"uri":"` + uri + `","author":{"did":"did:plc:a"},"likeCount":-1,"replyCount":0,"repostCount":0,"quoteCount":0}]}`} {
		p := Provider{Repo: repo, AppView: "https://api.bsky.app", HTTP: &http.Client{Transport: transport(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})}}
		if _, _, e := p.Inventory(context.Background(), "did:plc:a", time.Now()); e == nil {
			t.Fatal("invalid provider response accepted")
		}
	}
	v := Tracking{Impressions: 1, OutboundClicks: 2}
	v.CalculateCTR()
	if *v.CTR != 100 {
		t.Fatal("CTR exceeded 100")
	}
	if e := (Provider{Repo: repo}).Validate(context.Background(), "invalid"); e == nil {
		t.Fatal("invalid subject validated")
	}
}
