package corpuscore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestRemoteWireRollingVersionsAreOperationScoped(t *testing.T) {
	for _, path := range []string{"feed", "item", "catalog", "edition", "finance", "sports", "circle-candidates", "contract"} {
		for version := 0; version <= 4; version++ {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-Wire-Corpus-Contract", strconv.Itoa(version))
				w.Write([]byte(`{}`))
			}))
			remote := NewRemoteStore(RemoteConfig{server.URL, "appview", strings.Repeat("s", 32)}, server.Client())
			_, _, err := remote.request(context.Background(), "GET", "/internal/wire/v1/"+path, nil, true)
			minimum := 3
			if path == "feed" || path == "item" || path == "catalog" {
				minimum = 1
			}
			if path == "edition" {
				minimum = 2
			}
			if (err == nil) != (version >= minimum && version <= 3) {
				t.Fatal(path, version, err)
			}
			server.Close()
		}
	}
}
