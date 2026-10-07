package gateway

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestProxySignsTranslatedPathPreservesQueryAndDropsForgedTrust(t *testing.T) {
	secret := strings.Repeat("s", 32)
	up := httptest.NewServer(gatewaycore.InternalTrustMiddleware(secret, false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		if !ok || auth.DID != "did:plc:viewer" {
			t.Error("missing signed viewer")
		}
		if r.URL.Path != "/xrpc/app.thesocialwire.appview.getFeed" || r.URL.RawQuery != "q=a%2Bb+c" {
			t.Error(r.URL.String())
		}
		w.Header().Set("X-AppView-Feed-Source", "projection")
		w.Write([]byte(`{"ok":true}`))
	})))
	defer up.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL, AppViewSecret: secret}, Internal: up.Client()}
	req := httptest.NewRequest("GET", "https://gateway.invalid/v1/appview/feed?q=a%2Bb+c", nil)
	req.Header.Set("X-SocialWire-Internal-Did", "did:plc:forged")
	req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer", Authorization: "DPoP token", DPoP: "proof"}))
	w := httptest.NewRecorder()
	p.Handler(Route{Method: "GET", Target: "/xrpc/app.thesocialwire.appview.getFeed", UpstreamMethod: "GET", Service: "appview"}).ServeHTTP(w, req)
	if w.Code != 200 || w.Header().Get("X-AppView-Feed-Source") != "projection" {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
}
func TestProxyStreamingFlushesBeforeCompletionAndCancels(t *testing.T) {
	started := make(chan struct{})
	canceled := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Write([]byte("{\"first\":true}\n"))
		w.(http.Flusher).Flush()
		close(started)
		<-r.Context().Done()
		close(canceled)
	}))
	defer up.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL}, Internal: up.Client()}
	edge := httptest.NewServer(p.Handler(Route{Target: "/v1/appview/bootstrap-stream", UpstreamMethod: "GET", Service: "appview", Public: true, Streaming: true}))
	defer edge.Close()
	ctx, cancel := context.WithCancel(context.Background())
	r, _ := http.NewRequestWithContext(ctx, "GET", edge.URL, nil)
	res, e := edge.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	b := make([]byte, 15)
	if _, e = io.ReadFull(res.Body, b); e != nil {
		t.Fatal(e)
	}
	cancel()
	res.Body.Close()
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("upstream not canceled")
	}
}
func TestProxyBodyBoundAndLatrProofSeparation(t *testing.T) {
	count := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count++
		if r.Header.Get("DPoP") != "latr-proof" || r.Header.Get("X-Latr-API-Key") != "server-key" || r.Header.Get("Authorization") != "DPoP token" {
			t.Error("wrong credentials")
		}
		w.Write([]byte(`{}`))
	}))
	defer up.Close()
	p := Proxy{Config: Config{LatrURL: up.URL, LatrClientID: "id", LatrAPIKey: "server-key"}, Public: up.Client()}
	route := Route{Target: "/xrpc/link.latr.bookmarks.saveBookmark", UpstreamMethod: "POST", Service: "latr"}
	r := httptest.NewRequest("POST", "https://gateway.invalid/xrpc/link.latr.bookmarks.saveBookmark", strings.NewReader(`{}`))
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer", Authorization: "DPoP token", DPoP: "gateway-proof"}))
	w := httptest.NewRecorder()
	p.Handler(route).ServeHTTP(w, r)
	if w.Code != 400 || count != 0 {
		t.Fatal("missing distinct proof accepted")
	}
	r.Header.Set("X-Latr-Gateway-DPoP", "latr-proof")
	w = httptest.NewRecorder()
	p.Handler(route).ServeHTTP(w, r)
	if w.Code != 200 || count != 1 {
		t.Fatalf("%d", w.Code)
	}
}
func TestManifestRouteCoverage(t *testing.T) {
	b, e := io.ReadAll(mustOpen(t, "../../../../packages/spec/endpoint-manifest.json"))
	if e != nil {
		t.Fatal(e)
	}
	var manifest struct {
		Entries []struct{ Surface, Method, Path string }
	}
	if json.Unmarshal(b, &manifest) != nil {
		t.Fatal("bad manifest")
	}
	seen := map[string]bool{}
	for _, r := range Routes {
		seen[r.Method+" "+r.Path] = true
	}
	for _, e := range manifest.Entries {
		if e.Surface != "openapi" {
			continue
		}
		if strings.HasPrefix(e.Path, "/v1/appview/") || strings.HasPrefix(e.Path, "/v1/podcasts/") || strings.HasPrefix(e.Path, "/v1/operations/") || strings.HasPrefix(e.Path, "/xrpc/link.latr.") {
			if !seen[e.Method+" "+e.Path] {
				t.Errorf("missing %s %s", e.Method, e.Path)
			}
		}
	}
}

func mustOpen(t *testing.T, path string) *os.File {
	t.Helper()
	f, e := os.Open(path)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { f.Close() })
	return f
}
