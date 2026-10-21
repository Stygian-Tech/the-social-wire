package gateway

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

const draftPrefix = "/xrpc/app.thesocialwire.socialDraft."

func draftRoute(name string) Route {
	for _, route := range Routes {
		if route.Path == draftPrefix+name {
			return route
		}
	}
	panic("missing draft route")
}
func draftRequest(name string, body io.Reader) *http.Request {
	r := httptest.NewRequest("POST", draftPrefix+name, body)
	return r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:owner", Authorization: "DPoP token", DPoP: "proof"}))
}
func TestPrivateDraftRoutesRequireAuthentication(t *testing.T) {
	count := 0
	for _, route := range Routes {
		if !strings.HasPrefix(route.Path, draftPrefix) {
			continue
		}
		count++
		if route.Public || route.Optional || route.Target != route.Path || route.Service != "appview" {
			t.Fatalf("unsafe route: %+v", route)
		}
		p := Proxy{Config: Config{AppViewURL: "http://unused.invalid"}}
		for _, owner := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
			r := httptest.NewRequest(route.Method, route.Path, nil)
			if owner != "" {
				r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: owner}))
			}
			w := httptest.NewRecorder()
			p.Handler(route).ServeHTTP(w, r)
			if w.Code != 401 {
				t.Fatal(w.Code)
			}
		}
	}
	if count != 6 {
		t.Fatal(count)
	}
}
func TestPrivateDraftUploadStreamsWithHeadersAndTrust(t *testing.T) {
	secret := strings.Repeat("s", 32)
	size := int64(5 << 20)
	up := httptest.NewServer(gatewaycore.InternalTrustMiddleware(secret, false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		if !ok || auth.DID != "did:plc:owner" {
			t.Error("owner trust missing")
		}
		if r.ContentLength != size || r.Header.Get("Content-Type") != "application/octet-stream" || r.Header.Get("X-Social-Draft-Upload-Id") != "private-id" {
			t.Error("upload headers lost")
		}
		n, e := io.Copy(io.Discard, r.Body)
		if n != size || e != nil {
			t.Error(n, e)
		}
		w.Write([]byte(`{"attachment":{}}`))
	})))
	defer up.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL, AppViewSecret: secret}, Internal: up.Client()}
	r := draftRequest("uploadAttachment", strings.NewReader(strings.Repeat("a", int(size))))
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Social-Draft-Upload-Id", "private-id")
	w := httptest.NewRecorder()
	p.Handler(draftRoute("uploadAttachment")).ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
}
func TestPrivateDraftUploadBoundsBeforeReading(t *testing.T) {
	p := Proxy{Config: Config{AppViewURL: "http://unused.invalid"}}
	for _, tc := range []struct {
		length int64
		status int
	}{{-1, 411}, {0, 400}, {(100 << 20) + 1, 413}} {
		r := draftRequest("uploadAttachment", nil)
		r.ContentLength = tc.length
		r.Header.Set("Content-Type", "application/octet-stream")
		r.Header.Set("X-Social-Draft-Upload-Id", "id")
		w := httptest.NewRecorder()
		p.Handler(draftRoute("uploadAttachment")).ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatal(tc, w.Code)
		}
	}
}
func TestPrivateDraftUploadDoesNotBufferUntilEOF(t *testing.T) {
	arrived := make(chan struct{})
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, 1)
		if _, e := io.ReadFull(r.Body, b); e != nil {
			t.Error(e)
		}
		close(arrived)
		<-release
		io.Copy(io.Discard, r.Body)
		w.Write([]byte(`{}`))
	}))
	defer up.Close()
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL}, Internal: up.Client()}
	r := draftRequest("uploadAttachment", reader)
	r.ContentLength = 2
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Social-Draft-Upload-Id", "id")
	done := make(chan struct{})
	go func() {
		defer close(done)
		p.Handler(draftRoute("uploadAttachment")).ServeHTTP(httptest.NewRecorder(), r)
	}()
	writer.Write([]byte("a"))
	select {
	case <-arrived:
	case <-time.After(2 * time.Second):
		close(release)
		writer.Close()
		t.Fatal("upload buffered before upstream received first byte")
	}
	close(release)
	writer.Write([]byte("b"))
	writer.Close()
	<-done
}
func TestPrivateDraftDownloadStreamsAndForcesPrivateCache(t *testing.T) {
	released := make(chan struct{})
	defer close(released)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") == "application/x-ndjson" {
			t.Error("binary requested as NDJSON")
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Content-Length", "2")
		w.Header().Set("Cache-Control", "public, max-age=60")
		w.Write([]byte("a"))
		w.(http.Flusher).Flush()
		select {
		case <-released:
		case <-r.Context().Done():
		}
		w.Write([]byte("b"))
	}))
	defer up.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL}, Internal: up.Client()}
	edge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:owner", Authorization: "DPoP token", DPoP: "proof"}))
		p.Handler(draftRoute("getAttachment")).ServeHTTP(w, r)
	}))
	defer edge.Close()
	res, e := edge.Client().Get(edge.URL + "?assetId=private-id")
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	b := make([]byte, 1)
	if _, e = io.ReadFull(res.Body, b); e != nil || string(b) != "a" {
		t.Fatal(e)
	}
	if res.Header.Get("Cache-Control") != "private, no-store" || res.Header.Get("Content-Type") != "image/png" || res.ContentLength != 2 {
		t.Fatal(res.Header)
	}
}
