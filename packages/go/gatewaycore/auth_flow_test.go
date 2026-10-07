package gatewaycore

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"errors"
	jose "github.com/go-jose/go-jose/v4"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixtureTransport func(*http.Request) (*http.Response, error)

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func fixtureResponse(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}
func fixtureToken(t *testing.T, now time.Time) (string, string, *ecdsa.PrivateKey, jose.JSONWebKey) {
	t.Helper()
	proofKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	proofPublic := jose.JSONWebKey{Key: &proofKey.PublicKey}
	thumb, _ := proofPublic.Thumbprint(crypto.SHA256)
	signKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub := jose.JSONWebKey{Key: &signKey.PublicKey, KeyID: "signing", Algorithm: "ES256"}
	signer, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: signKey}, (&jose.SignerOptions{}).WithHeader("kid", "signing"))
	raw, _ := json.Marshal(map[string]any{"iss": "https://issuer.valid", "sub": "did:plc:fixture", "exp": now.Add(time.Hour).Unix(), "cnf": map[string]string{"jkt": Base64URLEncode(thumb)}, "client_id": "allowed"})
	signed, _ := signer.Sign(raw)
	token, _ := signed.CompactSerialize()
	return token, Base64URLEncode(thumb), proofKey, pub
}
func fixtureProof(t *testing.T, key *ecdsa.PrivateKey, token, htu, jti string, now time.Time) string {
	t.Helper()
	signer, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: key}, (&jose.SignerOptions{}).WithType("dpop+jwt").WithHeader("jwk", jose.JSONWebKey{Key: &key.PublicKey}))
	raw, _ := json.Marshal(map[string]any{"iat": now.Unix(), "htm": "GET", "htu": htu, "jti": jti, "ath": AccessTokenATH(token)})
	sig, _ := signer.Sign(raw)
	proof, _ := sig.CompactSerialize()
	return proof
}
func fixtureClient(t *testing.T, pub jose.JSONWebKey, empty bool, sessionCode int, sessionBody string) *http.Client {
	t.Helper()
	keys, _ := json.Marshal(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{pub}})
	if empty {
		keys = []byte(`{"keys":[]}`)
	}
	return &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case "https://plc.directory/did:plc:fixture":
			return fixtureResponse(200, `{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.valid"}]}`), nil
		case "https://pds.valid/.well-known/oauth-protected-resource":
			return fixtureResponse(200, `{"authorization_servers":["https://issuer.valid"]}`), nil
		case "https://issuer.valid/.well-known/oauth-authorization-server":
			return fixtureResponse(200, `{"issuer":"https://issuer.valid","jwks_uri":"https://issuer.valid/keys"}`), nil
		case "https://issuer.valid/keys":
			return fixtureResponse(200, string(keys)), nil
		case "https://pds.valid/xrpc/com.atproto.server.getSession":
			resp := fixtureResponse(sessionCode, sessionBody)
			if sessionCode == 401 {
				resp.Header.Set("DPoP-Nonce", "challenge")
			}
			return resp, nil
		default:
			t.Errorf("unexpected endpoint %s", r.URL.String())
			return fixtureResponse(404, ""), nil
		}
	})}
}
func TestIssuerJWKSAuthenticationAndReplay(t *testing.T) {
	now := time.Now()
	token, _, key, pub := fixtureToken(t, now)
	client := fixtureClient(t, pub, false, 200, "")
	handler := AuthMiddleware(AuthConfig{RequireKnownClient: true, AllowedClientIDs: []string{"allowed"}}, client)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a, ok := AuthContextFrom(r.Context())
		if !ok || a.DID != "did:plc:fixture" {
			t.Error("missingverifiedcontext")
		}
		w.WriteHeader(204)
	}))
	proof := fixtureProof(t, key, token, "https://api.valid/feed", "first", now)
	for _, want := range []int{204, 401} {
		r := httptest.NewRequest("GET", "https://api.valid/feed?a=1", nil)
		r.Header.Set("Authorization", "DPoP "+token)
		r.Header.Set("DPoP", proof)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("want%d got%d %s", want, w.Code, w.Body.String())
		}
	}
}
func TestActivePDSAttestationReceiptAndPreparedRequest(t *testing.T) {
	now := time.Now()
	token, _, key, pub := fixtureToken(t, now)
	config := AuthConfig{AttestationSecret: strings.Repeat("s", 32)}
	client := fixtureClient(t, pub, true, 200, `{"did":"did:plc:fixture","active":true}`)
	handler := AuthMiddleware(config, client)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	call := func(jti, receipt string, prepared bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "https://api.valid/feed", nil)
		r.Header.Set("Authorization", "DPoP "+token)
		r.Header.Set("DPoP", fixtureProof(t, key, token, "https://api.valid/feed", jti, time.Now()))
		r.Header.Set(SessionDPoPHeader, fixtureProof(t, key, token, "https://pds.valid/xrpc/com.atproto.server.getSession", "session-"+jti, time.Now()))
		if prepared {
			r.Header.Set(UpstreamPreparedHeader, "true")
		}
		if receipt != "" {
			r.Header.Set(ReceiptHeader, receipt)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	fresh := call("first", "", false)
	if fresh.Code != 204 || fresh.Header().Get(ReceiptHeader) == "" {
		t.Fatalf("%d %s", fresh.Code, fresh.Body.String())
	}
	missing := call("second", "", true)
	if missing.Code != 428 || missing.Header().Get(ReceiptRequiredHeader) != "true" {
		t.Fatal(missing.Code)
	}
	accepted := call("third", fresh.Header().Get(ReceiptHeader), true)
	if accepted.Code != 204 {
		t.Fatalf("%d %s", accepted.Code, accepted.Body.String())
	}
	bad := call("fourth", fresh.Header().Get(ReceiptHeader)+"x", true)
	if bad.Code != 401 {
		t.Fatal(bad.Code)
	}
}
func TestPDSNonceAndInactiveSessionFailClosed(t *testing.T) {
	now := time.Now()
	token, _, key, pub := fixtureToken(t, now)
	for _, tc := range []struct {
		code  int
		body  string
		nonce bool
	}{{401, "", true}, {200, `{"did":"did:plc:fixture","active":false}`, false}, {200, `{"did":"did:plc:attacker","active":true}`, false}, {500, "", false}} {
		handler := AuthMiddleware(AuthConfig{AttestationSecret: strings.Repeat("s", 32)}, fixtureClient(t, pub, true, tc.code, tc.body))(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("invalidsessionreachedhandler") }))
		r := httptest.NewRequest("GET", "https://api.valid/feed", nil)
		r.Header.Set("Authorization", "DPoP "+token)
		r.Header.Set("DPoP", fixtureProof(t, key, token, "https://api.valid/feed", "unique", now))
		r.Header.Set(SessionDPoPHeader, fixtureProof(t, key, token, "https://pds.valid/xrpc/com.atproto.server.getSession", "session", now))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		want := 401
		if tc.code == 500 {
			want = 503
		}
		if w.Code != want {
			t.Fatalf("got%d want%d", w.Code, want)
		}
		if tc.nonce && w.Header().Get(SessionNonceHeader) != "challenge" {
			t.Fatal("missingnonce")
		}
	}
}
func TestSupplementalKeyRejectionNeverFallsBack(t *testing.T) {
	now := time.Now()
	token, _, _, pub := fixtureToken(t, now)
	_, _, _, other := fixtureToken(t, now)
	raw, _ := json.Marshal(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{other}})
	v := TokenVerifier{Client: fixtureClient(t, pub, true, 200, ""), PLCURL: "https://plc.directory", SupplementalJWKS: string(raw)}
	if _, e := v.Verify(context.Background(), token, now); !errors.Is(e, ErrAuthentication) {
		t.Fatal(e)
	}
}
func TestReceiptBoundaries(t *testing.T) {
	now := time.Unix(1800000000, 0)
	a, e := NewAttestationReceipt(strings.Repeat("x", 32))
	if e != nil {
		t.Fatal(e)
	}
	r, e := a.Issue("token", "did:plc:test", "jkt", now.Add(time.Hour), now.Add(50*time.Second), now)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.Verify(r, "token", "did:plc:test", "jkt", now.Add(time.Hour), now); e != nil {
		t.Fatal(e)
	}
	for _, token := range []string{"changed", strings.Repeat("x", 32769)} {
		if _, e = a.Verify(r, token, "did:plc:test", "jkt", now.Add(time.Hour), now); e == nil {
			t.Fatal("acceptedwrongtoken")
		}
	}
	if _, e = a.Verify(r, "token", "did:plc:test", "jkt", now.Add(time.Hour), now.Add(51*time.Second)); !errors.Is(e, ErrReceiptExpired) {
		t.Fatal(e)
	}
}
func TestPublicURLNormalizationRetainsPortAndRejectsUnsafe(t *testing.T) {
	if got, e := NormalizePublicRemoteBase("https://pds.valid:8443/path/?q=1"); e != nil || got != "https://pds.valid:8443/path" {
		t.Fatal(got, e)
	}
	for _, u := range []string{"http://pds.valid", "https://localhost", "https://127.0.0.1", "https://x.railway.internal", "https://user:pass@pds.valid", "https://pds.valid/#fragment"} {
		if _, e := NormalizePublicRemoteBase(u); e == nil {
			t.Fatal(u)
		}
	}
}
func TestAuthDependencyFailureNeverAllowsFallback(t *testing.T) {
	now := time.Now()
	token, _, _, _ := fixtureToken(t, now)
	v := TokenVerifier{PLCURL: "https://plc.directory", Client: &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) { return nil, errors.New("upstream unavailable") })}}
	if _, e := v.Verify(context.Background(), token, now); !errors.Is(e, ErrAuthDependency) {
		t.Fatal(e)
	}
}
func TestConcurrentPublicCacheJoinsFetch(t *testing.T) {
	calls := 0
	var mu sync.Mutex
	v := TokenVerifier{Client: &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		time.Sleep(20 * time.Millisecond)
		return fixtureResponse(200, `{"keys":[]}`), nil
	})}}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Go(func() {
			data, status, e := v.cachedFetch(context.Background(), "https://issuer.valid/keys", 1024, false)
			if e != nil || status != 200 || !bytes.Contains(data, []byte("keys")) {
				t.Error("fetchfailed")
			}
		})
	}
	wg.Wait()
	if calls != 1 {
		t.Fatal(calls)
	}
}
