package gateway

import (
	"context"
	"encoding/json"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestConfigFailsClosedHostedAndAcceptsExactReceiptVariable(t *testing.T) {
	for _, env := range []map[string]string{{"APP_ENV": "dev"}, {"APP_ENV": "dev", "DATABASE_URL": "fixture"}, {"APP_ENV": "dev", "DATABASE_URL": "fixture", "PDS_ATTESTATION_RECEIPT_SECRET": strings.Repeat("s", 32), "WIRE_FEED_MODE": "wrong"}} {
		if _, e := ParseConfig(env); e == nil {
			t.Fatal("invalid hosted config accepted")
		}
	}
	c, e := ParseConfig(map[string]string{"APP_ENV": "dev", "DATABASE_URL": "fixture", "PDS_ATTESTATION_RECEIPT_SECRET": strings.Repeat("s", 32), "FINANCE_FEED_MODE": "visible", "WIRE_FEED_MODE": "shadow", "SPORTS_FEED_MODE": "api"})
	if e != nil || !c.Serves("finance") || c.Serves("wire") || !c.Serves("sports") {
		t.Fatal(c, e)
	}
}
func TestMetadataRetainsGatewayIdentityAndSeparateWebRedirect(t *testing.T) {
	c, _ := ParseConfig(map[string]string{"OAUTH_PUBLIC_ORIGIN": "https://web.valid", "OAUTH_IOS_METADATA_ORIGIN": "https://api.native.valid", "OAUTH_OPERATIONS_ORIGIN": "https://ops.valid"})
	s := Server{Config: c}
	for _, test := range []struct{ path, id, redirect string }{{"/oauth/client-metadata.json", "https://gateway.valid/oauth-client-metadata.json", "https://web.valid/callback"}, {"/ios-client-metadata.json", "https://api.native.valid/ios-client-metadata.json", "valid.native.api:/oauth/callback"}, {"/operations-oauth-client-metadata.json", "https://gateway.valid/operations-oauth-client-metadata.json", "https://ops.valid/callback"}} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "https://gateway.valid"+test.path, nil)
		s.metadata(w, r)
		var doc struct {
			ClientID  string   `json:"client_id"`
			Redirects []string `json:"redirect_uris"`
		}
		json.Unmarshal(w.Body.Bytes(), &doc)
		if w.Code != 200 || doc.ClientID != test.id || len(doc.Redirects) != 1 || doc.Redirects[0] != test.redirect {
			t.Fatal(w.Body.String())
		}
	}
}
func TestPublishedOAuthScopeParity(t *testing.T) {
	for _, fixture := range []struct{ path, scope string }{{"../../../../apps/web/public/client-metadata.json", webScope}, {"../../../../apps/web/public/ios-client-metadata.json", iosScope}} {
		raw, e := os.ReadFile(fixture.path)
		if e != nil {
			t.Fatal(e)
		}
		var d struct{ Scope string }
		json.Unmarshal(raw, &d)
		if d.Scope != fixture.scope {
			t.Fatal("scope drift")
		}
	}
}
func TestRateLimitReplicaSharingAndRefill(t *testing.T) {
	m := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: m.Addr()})
	defer client.Close()
	namespace := socialwireredis.NewKeyNamespace("dev", "")
	a, b := RequestLimiter{Redis: client, Namespace: namespace}, RequestLimiter{Redis: client, Namespace: namespace}
	at := time.Now()
	for i := 0; i < 30; i++ {
		l := &a
		if i%2 == 0 {
			l = &b
		}
		if !l.consume(context.Background(), "address", false, at) {
			t.Fatal("limit early")
		}
	}
	if a.consume(context.Background(), "address", false, at) {
		t.Fatal("burst exceeded")
	}
	if !b.consume(context.Background(), "address", false, at.Add(time.Second)) {
		t.Fatal("no refill")
	}
	if !b.consume(context.Background(), "address", true, at) {
		t.Fatal("audience collision")
	}
}
func TestIngestionEvidenceDoesNotExtendCompleteness(t *testing.T) {
	at := time.Now()
	expired := at.Add(-time.Second)
	s := Server{evidence: Evidence{Service: "gateway", PoolReadiness: "ready", Freshness: "unknown", Completeness: "degraded", ValidUntil: &expired}}
	e := s.Evidence(at)
	if e.PoolReadiness != "stale" || e.Completeness != "unknown" {
		t.Fatal(e)
	}
}
