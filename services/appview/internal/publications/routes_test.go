package publications

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicationRoutesRequireVerifiedIdentity(t *testing.T) {
	mux := http.NewServeMux()
	(Routes{}).Register(mux)
	for _, route := range []struct{ method, path string }{{"GET", "/v1/publications/sidebar"}, {"POST", "/v1/publications/refresh"}, {"POST", "/v1/publications/resolve"}, {"GET", "/v1/appview/bootstrap-stream"}, {"POST", "/v1/appview/enroll"}, {"GET", "/xrpc/app.thesocialwire.publication.getSidebar"}, {"POST", "/xrpc/app.thesocialwire.publication.resolvePublication"}} {
		for _, anonymous := range []bool{false, true} {
			req := httptest.NewRequest(route.method, route.path, nil)
			if anonymous {
				req = req.WithContext(gatewaycore.ContextWithAuth(context.Background(), gatewaycore.AuthContext{DID: gatewaycore.AnonymousDiscoveryDID}))
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != 401 {
				t.Fatalf("%s %s auth status %d", route.method, route.path, w.Code)
			}
		}
	}
}
func TestPublicationResolveBoundedBodyAndATURI(t *testing.T) {
	mux := http.NewServeMux()
	(Routes{Resolver: publicationcore.Resolver{}}).Register(mux)
	for _, body := range []string{`{"input":"at://did:plc:author/site.standard.publication/a"}`, `{"input":""} {"input":"extra"}`} {
		req := httptest.NewRequest("POST", "/v1/publications/resolve", strings.NewReader(body))
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer"}))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		want := 200
		if strings.Contains(body, "extra") {
			want = 400
		}
		if w.Code != want {
			t.Fatalf("status %d want %d: %s", w.Code, want, w.Body.String())
		}
		if want == 200 && !strings.Contains(w.Body.String(), `"kind":"standard-site"`) {
			t.Fatal(w.Body.String())
		}
	}
}
