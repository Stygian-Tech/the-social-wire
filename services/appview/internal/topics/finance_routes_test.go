package topics

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFinanceResponseShapesBoundsAndCompositionAuth(t *testing.T) {
	mux := http.NewServeMux()
	Routes{FinanceStore: &topicreadcore.FinanceStore{}}.Register(mux)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getFinanceSectors", nil))
	var body map[string]json.RawMessage
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || body["sectors"] == nil || w.Header().Get("Vary") != "" || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	request := httptest.NewRequest("POST", "/xrpc/app.thesocialwire.discovery.recordFinanceComposition", strings.NewReader(`{"event":"published","suggestionCount":3}`))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, request)
	if w.Code != 401 {
		t.Fatal(w.Code)
	}
	request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "viewer"}))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, request)
	if w.Code != 200 || w.Body.String() != `{"accepted":true}` {
		t.Fatal(w.Code, w.Body.String())
	}
	for _, raw := range []string{`{"event":"published"}`, `{"event":"other","suggestionCount":0}`, `{"event":"published","suggestionCount":4}`} {
		request = httptest.NewRequest("POST", "/xrpc/app.thesocialwire.discovery.recordFinanceComposition", strings.NewReader(raw))
		request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "viewer"}))
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, request)
		if w.Code != 400 {
			t.Fatal(raw, w.Code)
		}
	}
}
func TestCircleRoutesRequireViewerAndSixProofs(t *testing.T) {
	mux := http.NewServeMux()
	Routes{Circle: &topicreadcore.CircleService{}}.Register(mux)
	for _, route := range []struct{ method, path string }{{"GET", "getCircleCatalog"}, {"GET", "getCircleEdition"}, {"POST", "setCircleItemHidden"}} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(route.method, "/xrpc/app.thesocialwire.discovery."+route.path, nil))
		if w.Code != 401 {
			t.Fatal(route.path, w.Code)
		}
	}
	request := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getCircleEdition", nil)
	request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "viewer"}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, request)
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
}
