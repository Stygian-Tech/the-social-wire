package lists

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestListRoutesRequireVerifiedAuthentication(t *testing.T) {
	mux := http.NewServeMux()
	(Routes{}).Register(mux)
	for _, route := range []struct{ method, path string }{{"GET", "/v1/lists"}, {"GET", "/v1/lists/search?creator=author"}, {"POST", "/v1/lists/resolve"}, {"POST", "/v1/lists/refresh"}} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(route.method, route.path, nil))
		if w.Code != 401 {
			t.Fatalf("%s status %d", route.path, w.Code)
		}
	}
}
