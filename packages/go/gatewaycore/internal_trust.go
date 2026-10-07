package gatewaycore

import (
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const InternalDIDHeader = "X-SocialWire-Gateway-DID"
const InternalTimestampHeader = "X-SocialWire-Gateway-Timestamp"
const InternalSignatureHeader = "X-SocialWire-Gateway-Signature"

var ErrInternalTrust = errors.New("invalid gateway internal trust")

func CanonicalSignedPath(path string) string {
	path = strings.TrimSpace(path)
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	if path == "" {
		return "/"
	}
	if !strings.HasPrefix(path, "/") {
		return "/" + path
	}
	return path
}
func internalSignature(secret, method, path, did, stamp string) string {
	h := hmac.New(sha256.New, []byte(secret))
	h.Write([]byte(strings.Join([]string{stamp, strings.ToUpper(method), CanonicalSignedPath(path), did}, "\n")))
	return Base64URLEncode(h.Sum(nil))
}
func SignedInternalHeaders(secret, method, path, did string, at time.Time) (http.Header, error) {
	did = strings.TrimSpace(did)
	if strings.TrimSpace(secret) == "" || !strings.HasPrefix(did, "did:") {
		return nil, ErrInternalTrust
	}
	stamp := strconv.FormatInt(at.Unix(), 10)
	h := make(http.Header)
	h.Set(InternalDIDHeader, did)
	h.Set(InternalTimestampHeader, stamp)
	h.Set(InternalSignatureHeader, internalSignature(secret, method, path, did, stamp))
	return h, nil
}
func VerifyInternalHeaders(secret, method, path string, h http.Header, at time.Time) error {
	did := strings.TrimSpace(h.Get(InternalDIDHeader))
	stamp := strings.TrimSpace(h.Get(InternalTimestampHeader))
	n, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil || strings.TrimSpace(secret) == "" || !strings.HasPrefix(did, "did:") || at.Sub(time.Unix(n, 0)).Abs() > 120*time.Second {
		return ErrInternalTrust
	}
	expected := internalSignature(secret, method, path, did, strconv.FormatInt(n, 10))
	if !hmac.Equal([]byte(expected), []byte(strings.TrimSpace(h.Get(InternalSignatureHeader)))) {
		return ErrInternalTrust
	}
	return nil
}

// InternalTrustMiddleware precedes AuthMiddleware. Missing trust falls through to
// normal token authentication; a present invalid signature is never a fallback.
func InternalTrustMiddleware(secret string, allowAnonymous bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, ok := AuthContextFrom(r.Context()); ok || secret == "" {
				next.ServeHTTP(w, r)
				return
			}
			if strings.TrimSpace(r.Header.Get(InternalDIDHeader)) == "" || strings.TrimSpace(r.Header.Get(InternalTimestampHeader)) == "" || strings.TrimSpace(r.Header.Get(InternalSignatureHeader)) == "" {
				next.ServeHTTP(w, r)
				return
			}
			if VerifyInternalHeaders(secret, r.Method, r.URL.EscapedPath(), r.Header, time.Now()) != nil {
				http.Error(w, "Invalid gateway internal trust headers", http.StatusUnauthorized)
				return
			}
			did := strings.TrimSpace(r.Header.Get(InternalDIDHeader))
			auth := strings.TrimSpace(r.Header.Get("Authorization"))
			if auth == "" && !(allowAnonymous && did == AnonymousDiscoveryDID) {
				http.Error(w, "Missing Authorization header for gateway-proxied request", http.StatusUnauthorized)
				return
			}
			a := AuthContext{did, auth, strings.TrimSpace(r.Header.Get("DPoP")), strings.TrimSpace(r.Header.Get("X-ATProto-Upstream-DPoP"))}
			next.ServeHTTP(w, r.WithContext(ContextWithAuth(r.Context(), a)))
		})
	}
}
