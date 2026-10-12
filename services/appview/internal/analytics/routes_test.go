package analytics

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/analyticscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fixture struct {
	author, viewer   string
	event            analyticscore.Event
	valid, inventory int
	saved            bool
}

func (f *fixture) Save(_ context.Context, a string, _ []analyticscore.Item, _ bool, _ time.Time) error {
	f.author = a
	f.saved = true
	return nil
}
func (f *fixture) Record(_ context.Context, v, a string, e analyticscore.Event, _ time.Time) error {
	f.viewer = v
	f.author = a
	f.event = e
	return nil
}
func (f *fixture) Summary(_ context.Context, a string, _, _ int, _ string, _ time.Time) (analyticscore.Summary, error) {
	f.author = a
	return analyticscore.Summary{Items: []analyticscore.Item{}, Series: []analyticscore.Day{}}, nil
}
func (f *fixture) Inventory(_ context.Context, _ string, _ time.Time) ([]analyticscore.Item, bool, error) {
	f.inventory++
	return nil, true, nil
}
func (f *fixture) Validate(context.Context, string) error { f.valid++; return nil }
func TestAuthenticationCanonicalAuthorIsolationAndRateAdmission(t *testing.T) {
	f := &fixture{}
	mux := http.NewServeMux()
	Routes{Enabled: true, Store: f, Provider: f, Limits: &Limits{}}.Register(mux)
	call := func(method, path, body, did string) int {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if did != "" {
			r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: did}))
		}
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		return w.Code
	}
	if call("GET", "/v1/analytics/summary", "", "") != 401 {
		t.Fatal("unguarded")
	}
	if call("GET", "/v1/analytics/summary?cursor=at://did:plc:b/app.bsky.feed.post/a", "", "did:plc:a") != 400 {
		t.Fatal("cross-account cursor")
	}
	if call("GET", "/v1/analytics/summary?days=0", "", "did:plc:a") != 400 {
		t.Fatal("unbounded range")
	}
	if call("GET", "/v1/analytics/summary", "", "did:plc:a") != 200 || f.author != "did:plc:a" {
		t.Fatal("summary account")
	}
	body := `{"subjectUri":"at://did:plc:b/app.bsky.feed.post/a","event":"impression","surface":"social-feed"}`
	if call("POST", "/v1/analytics/events", body, "did:plc:a") != 202 || f.author != "did:plc:b" || f.viewer != "did:plc:a" || f.valid != 1 {
		t.Fatal("canonical author tracking")
	}
	if call("POST", "/v1/analytics/events", strings.Replace(body, "social-feed", "article-feed", 1), "did:plc:a") != 202 {
		t.Fatal("article feed rejected")
	}
	if call("POST", "/v1/analytics/events", body, "did:plc:b") != 202 || f.valid != 2 {
		t.Fatal("self counted")
	}
	if call("POST", "/v1/analytics/events", strings.Replace(body, `"surface"`, `"author"`, 1), "did:plc:a") != 400 {
		t.Fatal("accepted spoofed fields")
	}
	if call("POST", "/v1/analytics/refresh", "", "did:plc:a") != 200 || !f.saved {
		t.Fatal("refresh")
	}
	if call("POST", "/v1/analytics/refresh", "", "did:plc:a") != 429 || f.inventory != 1 {
		t.Fatal("refresh rate")
	}
}
func TestLimitsBoundKeysAndExpire(t *testing.T) {
	l := &Limits{}
	at := time.Now()
	if !l.Allow("v", at, 1) || l.Allow("v", at, 1) || !l.Allow("v", at.Add(time.Minute), 1) {
		t.Fatal("admission lifecycle")
	}
}

func TestCanonicalCacheReusesSuccessfulOwnershipWithoutSkippingInitialValidation(t *testing.T) {
	f := &fixture{}
	p := &CachedProvider{Base: f}
	for i := 0; i < 3; i++ {
		if e := p.Validate(context.Background(), "at://did:plc:a/app.bsky.feed.post/one"); e != nil {
			t.Fatal(e)
		}
	}
	if f.valid != 1 {
		t.Fatal("ownership was not cached", f.valid)
	}
	p.mu.Lock()
	p.cache["at://did:plc:a/app.bsky.feed.post/one"] = ownership{until: time.Now().Add(-time.Minute)}
	p.mu.Unlock()
	if e := p.Validate(context.Background(), "at://did:plc:a/app.bsky.feed.post/one"); e != nil || f.valid != 2 {
		t.Fatal("expired ownership not revalidated", e, f.valid)
	}
}

func TestDisabledToolsDoesNotRegisterAnalytics(t *testing.T) {
	mux := http.NewServeMux()
	// No storage/provider is supplied: disabled routes must never invoke either.
	Routes{Enabled: false}.Register(mux)
	for _, route := range []struct{ method, path string }{
		{"GET", "/v1/analytics/summary"}, {"POST", "/v1/analytics/refresh"}, {"POST", "/v1/analytics/events"},
	} {
		for _, did := range []string{"", "did:plc:viewer"} {
			r := httptest.NewRequest(route.method, route.path, nil)
			if did != "" {
				r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: did}))
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, r)
			if w.Code != http.StatusNotFound {
				t.Fatalf("%s=%d", route.path, w.Code)
			}
		}
	}
}
