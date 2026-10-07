package readstate

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestReadStateRoutesDenyUnauthenticatedAndAnonymous(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, test := range []struct{ method, path string }{{"GET", "getReadStateStatus"}, {"POST", "exportReadState"}, {"POST", "confirmReadState"}} {
		for _, did := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
			req := httptest.NewRequest(test.method, "/xrpc/app.thesocialwire.appview."+test.path, strings.NewReader(`{}`))
			if did != "" {
				req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: did}))
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != 401 || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("private request returned %d", w.Code)
			}
		}
	}
}

func TestConfirmationRejectsMissingCIDAndTrailingJSON(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, body := range []string{`{}`, `{"manifestCid":""}`, `{"manifestCid":"valid"} {}`, `{"manifestCid":17}`} {
		req := httptest.NewRequest("POST", "/xrpc/app.thesocialwire.appview.confirmReadState", strings.NewReader(body))
		req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer"}))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != 400 {
			t.Fatalf("invalid confirmation %s returned %d", body, w.Code)
		}
	}
}
