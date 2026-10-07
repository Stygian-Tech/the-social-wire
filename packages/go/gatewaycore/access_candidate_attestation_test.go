package gatewaycore

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

func TestPrivateHMACAccessTokenRequiresActivePDSAttestation(t *testing.T) {
	now := time.Now()
	original, _, key, pub := fixtureToken(t, now)
	payload, err := jose.ParseSignedCompact(original, []jose.SignatureAlgorithm{jose.ES256})
	if err != nil {
		t.Fatal(err)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.HS256, Key: []byte(strings.Repeat("private-key", 8))}, nil)
	if err != nil {
		t.Fatal(err)
	}
	signed, err := signer.Sign(payload.UnsafePayloadWithoutVerification())
	if err != nil {
		t.Fatal(err)
	}
	token, err := signed.CompactSerialize()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodePayload(token); err == nil {
		t.Fatal("general public JOSE parser admitted private algorithm")
	}
	if _, err := DecodeAccessCandidate(token, now); err != nil {
		t.Fatal("candidate inspection rejected issuer-private signature", err)
	}
	if err := verifyKeySet(token, []byte(`{"keys":[]}`)); !errors.Is(err, ErrNoPublicJWKS) {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		empty  bool
		status int
		body   string
		proof  bool
		want   int
	}{
		{"active", true, 200, `{"did":"did:plc:fixture","active":true}`, true, 204},
		{"no session proof", true, 200, `{"did":"did:plc:fixture"}`, false, 401},
		{"nonce", true, 401, `{}`, true, 401},
		{"different subject", true, 200, `{"did":"did:plc:other"}`, true, 401},
		{"dependency unavailable", true, 503, `{}`, true, 503},
		{"rate limited", true, 429, `{}`, true, 503},
		{"inactive", true, 200, `{"did":"did:plc:fixture","active":false}`, true, 401},
		{"public keys reject HMAC", false, 200, `{"did":"did:plc:fixture"}`, true, 401},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := fixtureClient(t, pub, tc.empty, tc.status, tc.body)
			handler := AuthMiddleware(AuthConfig{AttestationSecret: strings.Repeat("s", 32)}, client)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if a, ok := AuthContextFrom(r.Context()); !ok || a.DID != "did:plc:fixture" {
					t.Fatal("missing attested context")
				}
				w.WriteHeader(204)
			}))
			r := httptest.NewRequest("GET", "https://api.valid/feed", nil)
			r.Header.Set("Authorization", "DPoP "+token)
			r.Header.Set("DPoP", fixtureProof(t, key, token, "https://api.valid/feed", "gateway", now))
			if tc.proof {
				r.Header.Set(SessionDPoPHeader, fixtureProof(t, key, token, "https://pds.valid/xrpc/com.atproto.server.getSession", "session", now))
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("want %d got %d %s", tc.want, w.Code, w.Body.String())
			}
			if tc.name == "nonce" && w.Header().Get(SessionNonceHeader) != "challenge" {
				t.Fatal("nonce not preserved")
			}
		})
	}
	verifier := TokenVerifier{PLCURL: "https://plc.directory", Client: fixtureClient(t, pub, true, 200, `{}`)}
	if _, err := verifier.Verify(context.Background(), token, now); !errors.Is(err, ErrNoPublicJWKS) {
		t.Fatal(err)
	}
}

func TestAccessCandidateInspectionRejectsMalformedAndUnsignedTokens(t *testing.T) {
	now := time.Now()
	payload := Base64URLEncode([]byte(`{"iss":"https://issuer.valid","sub":"did:plc:fixture","exp":9999999999,"cnf":{"jkt":"key"}}`))
	for _, token := range []string{
		Base64URLEncode([]byte(`{"alg":"none"}`)) + "." + payload + ".",
		Base64URLEncode([]byte(`{"alg":"none"}`)) + "." + payload + ".AA",
		Base64URLEncode([]byte(`{}`)) + "." + payload + ".AA",
		Base64URLEncode([]byte(`{"alg":"HS256"}`)) + "." + Base64URLEncode([]byte(`null`)) + ".AA",
		"bad." + payload + ".AA",
	} {
		if _, err := DecodeAccessCandidate(token, now); err == nil {
			t.Fatal("accepted malformed candidate")
		}
	}
}
