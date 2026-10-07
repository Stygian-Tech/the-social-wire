package gateway

import (
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestProxySourceBudgetsAndMetadata(t *testing.T) {
	for _, tc := range []struct {
		service, path, accept, cache string
		budget                       time.Duration
		stream                       bool
	}{{"circle", "/xrpc/app.thesocialwire.discovery.getCircleEdition", "application/json", "private, no-store", 35 * time.Second, false}, {"operations", "/v1/operations/events/stream", "text/event-stream", "no-cache", 300 * time.Second, true}, {"appview", "/v1/podcasts/media", "", "private, no-store", 6 * time.Hour, true}} {
		t.Run(tc.service, func(t *testing.T) {
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Accept") != tc.accept {
					t.Error("accept", r.Header.Get("Accept"))
				}
				w.Header().Set("DPoP-Nonce", "retry-nonce")
				w.Header().Set("Location", "/next")
				w.Header().Set("Last-Modified", "yesterday")
				w.Header().Set("X-Accel-Buffering", "no")
				w.Header().Set("Content-Length", "2")
				w.WriteHeader(200)
				w.Write([]byte("{}"))
			}))
			defer up.Close()
			client := up.Client()
			underlying := client.Transport
			client.Transport = contractTransport(func(r *http.Request) (*http.Response, error) {
				deadline, ok := r.Context().Deadline()
				remaining := time.Until(deadline)
				if !ok || remaining > tc.budget || remaining < tc.budget-time.Second {
					t.Errorf("wrong total exchange budget: %v", remaining)
				}
				return underlying.RoundTrip(r)
			})
			p := Proxy{Config: Config{AppViewURL: up.URL, OperationsURL: up.URL}, Internal: client}
			r := httptest.NewRequest("GET", "https://gateway.invalid/a", nil)
			r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:v"}))
			w := httptest.NewRecorder()
			p.Handler(Route{Target: tc.path, UpstreamMethod: "GET", Service: tc.service, Streaming: tc.stream}).ServeHTTP(w, r)
			if w.Code != 200 || w.Header().Get("Cache-Control") != tc.cache || w.Header().Get("DPoP-Nonce") != "retry-nonce" {
				t.Fatal(w.Code, w.Header())
			}
			if tc.service == "operations" && (w.Header().Get("Location") != "/next" || w.Header().Get("Last-Modified") != "yesterday" || w.Header().Get("X-Accel-Buffering") != "no") {
				t.Fatal(w.Header())
			}
			if tc.path == "/v1/podcasts/media" && w.Header().Get("Content-Length") != "2" {
				t.Fatal(w.Header())
			}
		})
	}
}
func TestProxyMutationBodyBounds(t *testing.T) {
	for _, tc := range []struct {
		service string
		size    int
	}{{"wire", 4096}, {"circle", 64 << 10}, {"operations", 2 << 20}, {"appview", 4 << 20}} {
		p := Proxy{Config: Config{AppViewURL: "http://unused.invalid", OperationsURL: "http://unused.invalid"}}
		r := httptest.NewRequest("POST", "https://gateway.invalid/a", strings.NewReader(strings.Repeat("x", tc.size+1)))
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:v"}))
		w := httptest.NewRecorder()
		p.Handler(Route{Target: "/a", UpstreamMethod: "POST", Service: tc.service}).ServeHTTP(w, r)
		if w.Code != 413 {
			t.Fatal(tc.service, w.Code)
		}
	}
}

type contractTransport func(*http.Request) (*http.Response, error)

func (f contractTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
