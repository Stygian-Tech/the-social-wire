package gatewaycore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

type AuthConfig struct {
	Lifetime                                    *AuthLifetime
	PLCURL, SupplementalJWKS, AttestationSecret string
	RequireKnownClient                          bool
	AllowedClientIDs, AllowedAudiences          []string
}

func AuthMiddleware(config AuthConfig, client *http.Client) func(http.Handler) http.Handler {
	return newAuthMiddleware(config, client, false)
}
func OptionalAuthMiddleware(config AuthConfig, client *http.Client) func(http.Handler) http.Handler {
	return newAuthMiddleware(config, client, true)
}
func authError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	name := map[int]string{400: "InvalidRequest", 401: "AuthRequired", 403: "Forbidden", 503: "ServiceUnavailable"}[status]
	if name == "" {
		name = "InternalServerError"
	}
	json.NewEncoder(w).Encode(map[string]string{"error": name, "message": message})
}
func newAuthMiddleware(config AuthConfig, client *http.Client, optional bool) func(http.Handler) http.Handler {
	if client == nil {
		client = NewPublicHTTPClient(nil)
	}
	if config.PLCURL == "" {
		config.PLCURL = "https://plc.directory"
	}
	verifier := &TokenVerifier{Client: client, PLCURL: config.PLCURL, SupplementalJWKS: config.SupplementalJWKS, Lifetime: config.Lifetime}
	attestor := &PDSAttestor{Verifier: verifier}
	replay := &DPoPReplayGuard{}
	receipt, _ := NewAttestationReceipt(config.AttestationSecret)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, ok := AuthContextFrom(r.Context()); ok {
				next.ServeHTTP(w, r)
				return
			}
			authorization := strings.TrimSpace(r.Header.Get("Authorization"))
			if optional && authorization == "" {
				next.ServeHTTP(w, r)
				return
			}
			parts := strings.SplitN(authorization, " ", 2)
			if len(parts) != 2 || !(strings.EqualFold(parts[0], "Bearer") || strings.EqualFold(parts[0], "DPoP")) || strings.TrimSpace(parts[1]) == "" {
				authError(w, 401, "Authorization header must prefix DPoP or Bearer")
				return
			}
			token := strings.TrimSpace(parts[1])
			proof := strings.TrimSpace(r.Header.Get("DPoP"))
			if proof == "" || len(proof) > 8192 || strings.Contains(proof, ",") {
				authError(w, 401, "Missing RFC 9449 DPoP proof header")
				return
			}
			now := time.Now()
			candidate, e := verifier.Verify(r.Context(), token, now)
			var verified VerifiedDPoP
			responseNonce, responseReceipt := "", ""
			if e == nil {
				verified, e = VerifyDPoP(proof, r.Method, CanonicalHTU(r), token, candidate.JKT, now)
			} else if errors.Is(e, ErrNoPublicJWKS) && receipt != nil {
				candidate, e = DecodeAccessCandidate(token, now)
				if e == nil && !strings.HasPrefix(candidate.DID, "did:plc:") {
					e = ErrAuthentication
				}
				if e == nil {
					verified, e = VerifyDPoP(proof, r.Method, CanonicalHTU(r), token, candidate.JKT, now)
				}
				if e == nil {
					expires := time.Time{}
					requires := r.Header.Get("X-ATProto-Upstream-DPoP") != "" || strings.EqualFold(strings.TrimSpace(r.Header.Get(UpstreamPreparedHeader)), "true")
					if requires {
						raw := strings.TrimSpace(r.Header.Get(ReceiptHeader))
						if raw == "" {
							attestationRequired(w)
							return
						}
						expires, e = receipt.Verify(raw, token, candidate.DID, candidate.JKT, candidate.ExpiresAt, now)
						if errors.Is(e, ErrReceiptExpired) {
							attestationRequired(w)
							return
						}
					} else {
						var outcome AttestationOutcome
						outcome, e = attestor.Attest(r.Context(), token, authorization, strings.TrimSpace(r.Header.Get(SessionDPoPHeader)), verified, now)
						if e == nil {
							expires = outcome.ExpiresAt
							responseNonce = outcome.Nonce
						}
					}
					if e == nil {
						responseReceipt, e = receipt.Issue(token, candidate.DID, candidate.JKT, candidate.ExpiresAt, expires, time.Now())
					}
				}
			}
			if e != nil {
				var nonce NonceChallenge
				if errors.As(e, &nonce) {
					w.Header().Set(SessionNonceHeader, nonce.Nonce)
					w.WriteHeader(401)
					return
				}
				if errors.Is(e, ErrAuthDependency) {
					authError(w, 503, "ATProto authentication dependency unavailable")
					return
				}
				authError(w, 401, "Invalid or stale ATProto OAuth access token")
				return
			}
			if !clientAllowed(config, candidate) {
				authError(w, 403, "OAuth client is not authorized for this gateway")
				return
			}
			if replay.Consume(verified, time.Now()) != nil {
				authError(w, 401, "Invalid DPoP proof for this request")
				return
			}
			if responseNonce != "" {
				w.Header().Set(SessionNonceHeader, responseNonce)
			}
			if responseReceipt != "" {
				w.Header().Set(ReceiptHeader, responseReceipt)
			}
			auth := AuthContext{candidate.DID, authorization, proof, strings.TrimSpace(r.Header.Get("X-ATProto-Upstream-DPoP"))}
			next.ServeHTTP(w, r.WithContext(ContextWithAuth(r.Context(), auth)))
		})
	}
}
func clientAllowed(config AuthConfig, token AccessToken) bool {
	if !config.RequireKnownClient {
		return true
	}
	for _, id := range config.AllowedClientIDs {
		if id == token.ClientID || id == token.AZP {
			return true
		}
	}
	for _, allowed := range config.AllowedAudiences {
		for _, aud := range token.Audiences {
			if allowed == aud {
				return true
			}
		}
	}
	return false
}
func attestationRequired(w http.ResponseWriter) {
	w.Header().Set(ReceiptRequiredHeader, "true")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(428)
	w.Write([]byte(`{"error":"ATProtoSessionAttestationRequired"}`))
}
