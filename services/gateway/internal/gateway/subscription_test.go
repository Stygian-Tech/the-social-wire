package gateway

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestSubscriptionEntitlementsUseVerifiedViewerAndFailClosed(t *testing.T) {
	config, err := ParseConfig(map[string]string{"SOCIALWIRE_PRO_DIDS": " did:plc:pro ,did:web:brand.example "})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, did, plan string
		config          Config
		status          int
	}{
		{"missing authentication", "", "", config, 401},
		{"anonymous", gatewaycore.AnonymousDiscoveryDID, "", config, 401},
		{"empty grants", "did:plc:pro", "free", Config{}, 200},
		{"free viewer", "did:plc:free", "free", config, 200},
		{"pro viewer", "did:plc:pro", "pro", config, 200},
		{"exact matching", "did:plc:pro-other", "free", config, 200},
		{"brand requires own grant", "did:web:unlisted-brand.example", "free", config, 200},
		{"explicit brand grant", "did:web:brand.example", "pro", config, 200},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := Server{Config: test.config}
			r := httptest.NewRequest("GET", "/v1/subscription/entitlements?viewerDid=did:plc:pro&plan=pro", nil)
			r.Header.Set("X-SocialWire-Gateway-DID", "did:plc:pro")
			r.Header.Set("X-Subscription-Plan", "pro")
			if test.did != "" {
				r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: test.did}))
			}
			w := httptest.NewRecorder()
			s.Handler().ServeHTTP(w, r)
			if w.Code != test.status {
				t.Fatal(w.Code, w.Body.String())
			}
			if test.status == 200 {
				var result subscriptionEntitlements
				if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || result.Plan != test.plan || result.ViewerDID != test.did {
					t.Fatal(result, err)
				}
				if w.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatal("viewer entitlements must not be cached")
				}
			}
		})
	}
}

func TestCreatorToolsProxyRequiresProBeforeContactingUpstream(t *testing.T) {
	requests := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.Write([]byte(`{"ok":true}`))
	}))
	defer up.Close()
	p := Proxy{Config: Config{AppViewURL: up.URL, ProGatingEnabled: true, ProDIDs: map[string]bool{"did:plc:pro": true}}, Internal: up.Client()}
	for _, route := range Routes {
		if route.Target != "/v1/analytics/summary" && route.Target != "/v1/analytics/refresh" && route.Target != "/v1/analytics/events" && route.Target != "/xrpc/app.thesocialwire.appview.getFeed" {
			continue
		}
		for _, did := range []string{"", "did:plc:free", "did:plc:pro"} {
			t.Run(route.Path+"/"+did, func(t *testing.T) {
				r := httptest.NewRequest(route.Method, route.Path, nil)
				if did != "" {
					r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: did}))
				}
				before := requests
				w := httptest.NewRecorder()
				p.Handler(route).ServeHTTP(w, r)
				want := 200
				if did == "" {
					want = 401
				} else if did != "did:plc:pro" && (route.Target == "/v1/analytics/summary" || route.Target == "/v1/analytics/refresh") {
					want = 403
				}
				if w.Code != want {
					t.Fatal(w.Code, w.Body.String())
				}
				if want != 200 && requests != before {
					t.Fatal("blocked request reached upstream")
				}
				if want == 403 {
					var result map[string]string
					json.Unmarshal(w.Body.Bytes(), &result)
					if result["error"] != "ProRequired" {
						t.Fatal(result)
					}
				}
			})
		}
	}
}

func TestProGatingDefaultsOffWithoutBypassingAuthentication(t *testing.T) {
	for _, flag := range []string{"", "false", "true"} {
		config, err := ParseConfig(map[string]string{"SOCIALWIRE_PRO_GATING_ENABLED": flag})
		if err != nil {
			t.Fatal(err)
		}
		if config.ProGatingEnabled != (flag == "true") {
			t.Fatalf("unexpected gating for %q", flag)
		}
		if config.hasPro("did:plc:free") {
			t.Fatal("disabled gating must not grant a paid plan")
		}
		for _, did := range []string{"", gatewaycore.AnonymousDiscoveryDID, "did:plc:free"} {
			r := httptest.NewRequest("GET", "/v1/analytics/summary", nil)
			if did != "" {
				r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: did}))
			}
			w := httptest.NewRecorder()
			allowed := requirePro(w, r, config)
			want := http.StatusUnauthorized
			if did == "did:plc:free" {
				want = http.StatusOK
				if config.ProGatingEnabled {
					want = http.StatusForbidden
				}
			}
			if w.Code != want || allowed != (want == http.StatusOK) {
				t.Fatalf("flag=%q did=%q allowed=%v status=%d", flag, did, allowed, w.Code)
			}
		}
	}
}
