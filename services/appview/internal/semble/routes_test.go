package semble

import (
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRoutesGuardAuthenticationAndInputs(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, path := range []string{"/v1/semble/collections", "/v1/semble/collection", "/v1/semble/connections"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 401 {
			t.Fatal(path, w.Code)
		}
	}
	for _, path := range []string{"/v1/semble/collections?limit=0", "/v1/semble/collection", "/v1/semble/connections"} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", path, nil)
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:v"}))
		mux.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatal(path, w.Code, w.Body.String())
		}
	}
}
