package reader

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestReaderRoutesRequireAuthenticatedViewerBeforeDatabaseAccess(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, test := range []struct{ method, path string }{
		{"GET", "/v1/appview/feed"}, {"GET", "/xrpc/app.thesocialwire.appview.getFeed"},
		{"GET", "/v1/appview/entries"}, {"GET", "/v1/appview/entry"},
		{"POST", "/v1/appview/read-marks"}, {"DELETE", "/v1/appview/read-marks"},
		{"POST", "/xrpc/app.thesocialwire.appview.putReadMark"}, {"POST", "/xrpc/app.thesocialwire.appview.deleteReadMark"},
	} {
		for _, anonymous := range []bool{false, true} {
			r := httptest.NewRequest(test.method, test.path, nil)
			if anonymous {
				r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: gatewaycore.AnonymousDiscoveryDID}))
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, r)
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("%s %s anonymous=%v returned %d", test.method, test.path, anonymous, w.Code)
			}
		}
	}
}

func TestInvalidFeedInputsDoNotReachDatabase(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, query := range []string{"kind=unknown", "kind=folder", "kind=publication", "kind=subscribed&filter=unknown", "kind=subscribed&filter=", "kind=subscribed&limit=0", "kind=subscribed&limit=101", "kind=subscribed&limit=abc", "kind=subscribed&cursor=", "kind=subscribed&cursor=bad"} {
		r := httptest.NewRequest("GET", "/v1/appview/feed?"+query, nil)
		r.Header.Set("X-Request-ID", "fixture-request")
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer"}))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		var body map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if w.Code != 400 || body["error"] != "invalid_request" || body["requestId"] != "fixture-request" || body["retryable"] != false {
			t.Fatalf("%s => %d %v", query, w.Code, body)
		}
	}
}
