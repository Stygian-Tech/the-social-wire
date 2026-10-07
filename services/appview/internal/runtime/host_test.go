package runtime

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/config"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func hostFixture(t *testing.T, podcasts bool, overrides map[string]string) *Host {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL")
	if dsn == "" {
		dsn = os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("canonical PostgreSQL not configured")
	}
	if podcasts {
		dsn = os.Getenv("SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL")
		if dsn == "" {
			t.Skip("podcast-enabled canonical PostgreSQL not configured")
		}
	}
	env := map[string]string{"APP_ENV": "prod", "DATABASE_URL": dsn, "ENABLE_THIN_APPVIEW": "true", "OPERATIONS_TELEMETRY_ENABLED": "false", "GATEWAY_APPVIEW_INTERNAL_SECRET": strings.Repeat("i", 32)}
	if podcasts {
		env["PODCASTS_ENABLED"] = "true"
	}
	for k, v := range overrides {
		env[k] = v
	}
	h, e := NewHost(context.Background(), env)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if e := h.Close(ctx); e != nil {
			t.Error(e)
		}
	})
	return h
}
func serveHost(h *Host, method, path, did string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	if did != "" {
		r.Header.Set("Authorization", "DPoP gateway-bound-token")
		headers, _ := gatewaycore.SignedInternalHeaders(h.Config.InternalSecret, method, r.URL.Path, did, time.Now())
		for k, v := range headers {
			r.Header[k] = v
		}
	}
	w := httptest.NewRecorder()
	h.Handler.ServeHTTP(w, r)
	return w
}
func TestAppViewHostAuthAndServingMatrix(t *testing.T) {
	h := hostFixture(t, false, map[string]string{"WIRE_FEED_MODE": "visible", "FINANCE_FEED_MODE": "api", "SPORTS_FEED_MODE": "api", "CIRCLE_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("w", 32), "FINANCE_CURSOR_HMAC_SECRET": strings.Repeat("f", 32), "SPORTS_CURSOR_HMAC_SECRET": strings.Repeat("s", 32), "WIRE_ACTOR_HMAC_SECRET": strings.Repeat("a", 32), "CIRCLE_CURSOR_HMAC_SECRET": strings.Repeat("c", 32)})
	for _, route := range []string{"GET /v1/appview/feed", "GET /v1/appview/entries", "GET /v1/appview/entry", "GET /v1/appview/unread-counts", "GET /v1/appview/bootstrap-stream", "GET /v1/publications/sidebar", "POST /v1/publications/refresh", "POST /v1/publications/resolve", "POST /v1/appview/enroll", "GET /v1/lists", "GET /v1/lists/search", "POST /v1/lists/resolve", "POST /v1/lists/refresh", "POST /v1/appview/read-marks", "DELETE /v1/appview/read-marks", "DELETE /v1/appview/privacy/purge", "POST /v1/appview/mark-all-read", "GET /xrpc/app.thesocialwire.appview.getReadAgeOptions", "POST /xrpc/app.thesocialwire.appview.markReadBefore", "GET /xrpc/app.thesocialwire.appview.getReadStateStatus", "POST /xrpc/app.thesocialwire.appview.prepareReadState", "POST /xrpc/app.thesocialwire.appview.exportReadState", "POST /xrpc/app.thesocialwire.appview.confirmReadState", "GET /xrpc/app.thesocialwire.discovery.getWire", "GET /xrpc/app.thesocialwire.discovery.getWireEdition", "GET /xrpc/app.thesocialwire.discovery.getWireItem", "GET /xrpc/app.thesocialwire.discovery.getFeedCatalog", "GET /xrpc/app.thesocialwire.discovery.getFinance", "GET /xrpc/app.thesocialwire.discovery.getFinanceCatalog", "GET /xrpc/app.thesocialwire.discovery.getFinanceSectors", "GET /xrpc/app.thesocialwire.discovery.searchFinanceInstruments", "POST /xrpc/app.thesocialwire.discovery.recordFinanceComposition", "GET /xrpc/app.thesocialwire.discovery.getSports", "GET /xrpc/app.thesocialwire.discovery.getSportsCatalog", "GET /xrpc/app.thesocialwire.discovery.getSportsEvents", "GET /xrpc/app.thesocialwire.discovery.searchSportsEntities", "GET /xrpc/app.thesocialwire.discovery.getCircleEdition", "GET /xrpc/app.thesocialwire.discovery.getCircleCatalog", "POST /xrpc/app.thesocialwire.discovery.setCircleItemHidden"} {
		method, path, _ := strings.Cut(route, " ")
		w := serveHost(h, method, path, "")
		if w.Code != 401 {
			t.Errorf("%s without auth=%d %s", route, w.Code, w.Body.String())
		}
	}
	for _, path := range []string{"/health", "/livez", "/readyz", "/freshness"} {
		w := serveHost(h, "GET", path, "")
		if w.Code != 200 {
			t.Errorf("%s=%d %s", path, w.Code, w.Body.String())
		}
	}
	// An internal anonymous principal is admitted only to the discovery group.
	for _, path := range []string{"/v1/appview/feed", "/xrpc/app.thesocialwire.discovery.getCircleCatalog"} {
		if w := serveHost(h, "GET", path, gatewaycore.AnonymousDiscoveryDID); w.Code != 401 {
			t.Errorf("anonymous private %s=%d", path, w.Code)
		}
	}
	w := serveHost(h, "GET", "/xrpc/app.thesocialwire.discovery.getFeedCatalog", gatewaycore.AnonymousDiscoveryDID)
	if w.Code == 401 || w.Code == 404 {
		t.Fatalf("trusted discovery denied %d %s", w.Code, w.Body.String())
	}
	w = serveHost(h, "GET", "/xrpc/app.thesocialwire.appview.getReadStateStatus", "did:plc:host-readstate")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	r := httptest.NewRequest("GET", "/v1/appview/feed", nil)
	r.Header.Set("Authorization", "DPoP raw")
	r.Header.Set(gatewaycore.InternalDIDHeader, "did:plc:spoof")
	r.Header.Set(gatewaycore.InternalTimestampHeader, "1")
	r.Header.Set(gatewaycore.InternalSignatureHeader, "forged")
	bad := httptest.NewRecorder()
	h.Handler.ServeHTTP(bad, r)
	if bad.Code != 401 {
		t.Fatal("forged trust accepted", bad.Code)
	}
	if w := serveHost(h, "GET", "/v1/podcasts/shows", ""); w.Code != 404 {
		t.Fatal("disabled podcast route registered", w.Code)
	}
}
func TestPodcastHostFeatureAndMediaWorkerGates(t *testing.T) {
	h := hostFixture(t, true, nil)
	for _, path := range []string{"/v1/podcasts/shows", "/v1/podcasts/image", "/v1/podcasts/media"} {
		if w := serveHost(h, "GET", path, ""); w.Code != 401 {
			t.Errorf("%s=%d", path, w.Code)
		}
	}
	for _, path := range []string{"/v1/podcasts/assets", "/v1/podcasts/public/assets"} {
		if w := serveHost(h, "GET", path, ""); w.Code != 404 {
			t.Errorf("unconfigured worker %s=%d", path, w.Code)
		}
	}
	if w := serveHost(h, "GET", "/v1/podcasts/public/clips", ""); w.Code == 401 || !strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") {
		t.Fatal("public clip route missing", w.Code)
	}
	w := serveHost(h, "GET", "/v1/podcasts/shows", "did:plc:host-podcasts")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var payload map[string]any
	if json.Unmarshal(w.Body.Bytes(), &payload) != nil {
		t.Fatal(w.Body.String())
	}
}
func TestCircleOnlyDoesNotExposeWireCatalog(t *testing.T) {
	h := hostFixture(t, false, map[string]string{"CIRCLE_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("w", 32), "WIRE_ACTOR_HMAC_SECRET": strings.Repeat("a", 32), "CIRCLE_CURSOR_HMAC_SECRET": strings.Repeat("c", 32)})
	if w := serveHost(h, "GET", "/xrpc/app.thesocialwire.discovery.getFeedCatalog", ""); w.Code != 404 {
		t.Fatal(w.Code)
	}
}
func TestWireModeSourcePriority(t *testing.T) {
	env := map[string]string{"APP_ENV": "prod", "DATABASE_URL": "postgres://test/local", "ENABLE_THIN_APPVIEW": "true", "WIRE_FEED_MODE": "api", "SPORTS_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("w", 32)}
	c, e := config.Parse(env)
	if e != nil || c.WireMode != "api" {
		t.Fatal(c, e)
	}
}
