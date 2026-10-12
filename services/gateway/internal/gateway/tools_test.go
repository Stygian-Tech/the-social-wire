package gateway

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestToolsEnvironmentGate(t *testing.T) {
	for _, test := range []struct {
		environment, flag string
		enabled           bool
	}{
		{"prod", "", false}, {"prod", "false", false}, {"prod", "true", true},
		{"dev", "", true}, {"local", "", true}, {"dev", "false", false}, {"dev", "true", true}, {"prod", "invalid", false},
	} {
		t.Run(test.environment+"/"+test.flag, func(t *testing.T) {
			config, err := ParseConfig(map[string]string{"APP_ENV": test.environment, "TOOLS_ENABLED": test.flag, "DATABASE_URL": "fixture", "PDS_ATTESTATION_RECEIPT_SECRET": strings.Repeat("s", 32)})
			if err != nil {
				t.Fatal(err)
			}
			if config.ToolsEnabled != test.enabled {
				t.Fatalf("enabled=%v", config.ToolsEnabled)
			}
			requests := 0
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests++; w.WriteHeader(http.StatusNoContent) }))
			defer up.Close()
			config.AppViewURL = up.URL
			server := (&Server{Config: config, HTTP: up.Client()}).Handler()
			proxy := Proxy{Config: config, Internal: up.Client()}
			for _, route := range Routes {
				if !strings.HasPrefix(route.Target, "/v1/analytics/") {
					continue
				}
				for _, authenticated := range []bool{false, true} {
					request := httptest.NewRequest(route.Method, route.Path, nil)
					if authenticated {
						request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "did:plc:viewer"}))
					}
					for _, handler := range []http.Handler{server, proxy.Handler(route)} {
						before := requests
						response := httptest.NewRecorder()
						handler.ServeHTTP(response, request)
						want := http.StatusNotFound
						if test.enabled {
							want = http.StatusUnauthorized
							if authenticated {
								want = http.StatusNoContent
							}
						}
						if response.Code != want {
							t.Fatalf("%s authenticated=%v got=%d want=%d", route.Path, authenticated, response.Code, want)
						}
						if want != http.StatusNoContent && requests != before {
							t.Fatal("disabled or unauthenticated Tools request reached upstream")
						}
					}
				}
			}
		})
	}
}
