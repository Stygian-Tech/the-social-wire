package topics

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type routeCorpus struct {
	corpuscore.Store
	now time.Time
}

func (c routeCorpus) Feed(ctx context.Context, q corpuscore.FeedQuery, now time.Time) (corpuscore.Page, error) {
	return corpuscore.Page{GenerationID: "11111111-1111-1111-1111-111111111111", GeneratedAt: c.now, Language: q.Language, Source: "ranked", Exhausted: true, Rows: []corpuscore.Row{{Item: wirecore.FeedItem{ItemID: "a", Title: "Story", Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}}}}, nil
}
func (c routeCorpus) Catalog(context.Context, time.Time) (corpuscore.Catalog, error) {
	return corpuscore.Catalog{Available: true, SupportedLanguages: []string{"en"}, GeneratedAt: &c.now}, nil
}
func (c routeCorpus) Item(context.Context, string, time.Time) (*corpuscore.Item, error) {
	return nil, nil
}
func (c routeCorpus) Edition(context.Context, corpuscore.EditionQuery, time.Time) (corpuscore.Edition, error) {
	return corpuscore.Edition{Edition: wirecore.AssembleEdition("11111111-1111-1111-1111-111111111111", c.now, "en", nil, "ranked", false, nil, nil)}, nil
}
func routeFixture(t *testing.T, visible bool) (*http.ServeMux, *topicreadcore.ModerationService) {
	t.Helper()
	now := time.Date(2026, 10, 7, 12, 0, 0, 123456000, time.UTC)
	m := topicreadcore.NewModerationService(nil, nil)
	wire, err := topicreadcore.NewWireStore(routeCorpus{now: now}, strings.Repeat("a", 32), "visible", m.Cache)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	Routes{Wire: wire, Moderation: m, WireVisible: visible, Now: func() time.Time { return now }}.Register(mux)
	return mux, m
}
func TestWireRoutesAnonymousCachingAndAuthenticatedDenial(t *testing.T) {
	mux, m := routeFixture(t, true)
	url := "/xrpc/app.thesocialwire.discovery.getWire?lang=en"
	first := httptest.NewRecorder()
	mux.ServeHTTP(first, httptest.NewRequest("GET", url, nil))
	if first.Code != 200 || first.Header().Get("Cache-Control") != "public, max-age=60, stale-while-revalidate=300" || first.Header().Get("X-Wire-Source") != "ranked" {
		t.Fatal(first.Code, first.Header())
	}
	if strings.Contains(first.Body.String(), ".123456") {
		t.Fatal("fractional timestamp")
	}
	request := httptest.NewRequest("GET", url, nil)
	request.Header.Set("If-None-Match", first.Header().Get("ETag"))
	cached := httptest.NewRecorder()
	mux.ServeHTTP(cached, request)
	if cached.Code != 304 || cached.Body.Len() != 0 {
		t.Fatal(cached.Code)
	}
	request = httptest.NewRequest("GET", url, nil)
	request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "did:example:viewer"}))
	denied := httptest.NewRecorder()
	mux.ServeHTTP(denied, request)
	if denied.Code != 503 {
		t.Fatal(denied.Code)
	}
	m.Cache.Store("did:example:viewer", topicreadcore.ModerationSnapshot{FetchedAt: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)})
	request.Header.Set("If-None-Match", first.Header().Get("ETag"))
	accepted := httptest.NewRecorder()
	mux.ServeHTTP(accepted, request)
	if accepted.Code != 200 || accepted.Header().Get("Cache-Control") != "private, max-age=0" {
		t.Fatal(accepted.Code, accepted.Header())
	}
}
func TestWireRoutesVisibilityBoundsAndCatalogDates(t *testing.T) {
	mux, _ := routeFixture(t, false)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getWire", nil))
	if w.Code != 404 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getFeedCatalog", nil))
	var catalog map[string]any
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &catalog) != nil || catalog["enabled"] != false || catalog["generatedAt"] != "2026-10-07T12:00:00Z" {
		t.Fatal(w.Code, w.Body.String())
	}
	mux, _ = routeFixture(t, true)
	for _, path := range []string{"getWire?limit=0", "getWire?limit=51", "getWireEdition?region=us", "getWireItem?itemId="} {
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery."+path, nil))
		if w.Code != 400 {
			t.Fatal(path, w.Code)
		}
	}
}

func TestWireCatalogDoesNotLoadTopicCatalogs(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	wire, err := topicreadcore.NewWireStore(routeCorpus{now: now}, strings.Repeat("a", 32), "visible", &topicreadcore.ModerationCache{})
	if err != nil {
		t.Fatal(err)
	}
	// Uninitialized topic stores panic if catalog loading touches their database.
	routes := Routes{Wire: wire, WireVisible: true, FinanceStore: &topicreadcore.FinanceStore{}, SportsStore: &topicreadcore.SportsStore{}, Now: func() time.Time { return now }}
	mux := http.NewServeMux()
	routes.Register(mux)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getFeedCatalog", nil))
	var catalog map[string]any
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &catalog) != nil {
		t.Fatal(response.Code, response.Body.String())
	}
	if catalog["enabled"] != true || catalog["available"] != true || catalog["title"] != "The Wire" {
		t.Fatal(catalog)
	}
	for _, key := range []string{"finance", "financeAvailable", "sports", "sportsAvailable"} {
		if _, exists := catalog[key]; exists {
			t.Fatalf("unexpected topic field %q", key)
		}
	}
	if response.Body.Len() > 1024 {
		t.Fatalf("Wire metadata response grew to %d bytes", response.Body.Len())
	}
}
