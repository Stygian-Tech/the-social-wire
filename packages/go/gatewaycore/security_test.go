package gatewaycore

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	jose "github.com/go-jose/go-jose/v4"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestInternalTrustParityAndBoundaries(t *testing.T) {
	now := time.Unix(1800000000, 0)
	h, err := SignedInternalHeaders("secret", "get", "/v1/appview/feed?b=2", "did:plc:example", now)
	if err != nil {
		t.Fatal(err)
	}
	if err = VerifyInternalHeaders("secret", "GET", "/v1/appview/feed?a=1", h, now.Add(119*time.Second)); err != nil {
		t.Fatal(err)
	}
	for _, mutation := range []struct {
		secret, method, path string
		at                   time.Time
	}{{"wrong", "GET", "/v1/appview/feed", now}, {"secret", "POST", "/v1/appview/feed", now}, {"secret", "GET", "/different", now}, {"secret", "GET", "/v1/appview/feed", now.Add(121 * time.Second)}} {
		if VerifyInternalHeaders(mutation.secret, mutation.method, mutation.path, h, mutation.at) == nil {
			t.Fatal("accepted invalid internal trust")
		}
	}
}
func TestAnonymousTrustRequiresExplicitDiscovery(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a, ok := AuthContextFrom(r.Context())
		if !ok || a.DID != AnonymousDiscoveryDID {
			t.Fatal("auth absent")
		}
		w.WriteHeader(204)
	})
	for _, allow := range []bool{false, true} {
		r := httptest.NewRequest("GET", "https://appview/v1/feed", nil)
		r.Header, _ = SignedInternalHeaders("secret", "GET", "/v1/feed", AnonymousDiscoveryDID, time.Now())
		w := httptest.NewRecorder()
		InternalTrustMiddleware("secret", allow)(handler).ServeHTTP(w, r)
		want := 401
		if allow {
			want = 204
		}
		if w.Code != want {
			t.Fatalf("%d", w.Code)
		}
	}
}
func signedProof(t *testing.T, claims map[string]any) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub := jose.JSONWebKey{Key: &key.PublicKey}
	thumb, err := pub.Thumbprint(crypto.SHA256)
	if err != nil {
		t.Fatal(err)
	}
	opts := (&jose.SignerOptions{}).WithType("dpop+jwt").WithHeader("jwk", pub)
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: key}, opts)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(claims)
	signed, err := signer.Sign(raw)
	if err != nil {
		t.Fatal(err)
	}
	proof, err := signed.CompactSerialize()
	if err != nil {
		t.Fatal(err)
	}
	return proof, Base64URLEncode(thumb)
}
func TestDPoPVerifiedBindings(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	claims := map[string]any{"iat": now.Unix(), "jti": "unique", "htm": "GET", "htu": "https://api.example/feed", "ath": AccessTokenATH("token")}
	proof, jkt := signedProof(t, claims)
	v, err := VerifyDPoP(proof, "GET", "https://api.example/feed", "token", jkt, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		method, url, token, jkt string
		at                      time.Time
	}{{"POST", "https://api.example/feed", "token", jkt, now}, {"GET", "https://api.example/other", "token", jkt, now}, {"GET", "https://api.example/feed", "changed", jkt, now}, {"GET", "https://api.example/feed", "token", "wrong", now}, {"GET", "https://api.example/feed", "token", jkt, now.Add(121 * time.Second)}} {
		if _, err := VerifyDPoP(proof, c.method, c.url, c.token, c.jkt, c.at); err == nil {
			t.Fatal("accepted invalid proof binding")
		}
	}
	g := DPoPReplayGuard{MaximumEntries: 1}
	if g.Consume(v, now) != nil || g.Consume(v, now) == nil {
		t.Fatal("replay")
	}
	v.JTI = "second"
	if g.Consume(v, now) == nil {
		t.Fatal("capacity")
	}
	if g.Consume(v, now.Add(121*time.Second)) != nil {
		t.Fatal("expiry")
	}
}
func TestHTUExcludesQueryAndUsesIngressScheme(t *testing.T) {
	r := httptest.NewRequest("GET", "http://api.example/feed?a=1", nil)
	r.Header.Set("X-Forwarded-Proto", "https,http")
	if got := CanonicalHTU(r); got != "https://api.example/feed" {
		t.Fatal(got)
	}
}
