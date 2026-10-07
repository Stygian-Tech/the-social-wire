package operationsapi

import (
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
)

// This must run after validated Gateway internal trust or OAuth/DPoP authentication.
func OperatorAuthorization(allowed map[string]struct{}) func(http.Handler) http.Handler {
	// Configuration is immutable for the lifetime of a service instance.
	operators := map[string]struct{}{}
	for did := range allowed {
		operators[did] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			auth, ok := gatewaycore.AuthContextFrom(r.Context())
			if !ok || auth.DID == "" {
				writeError(w, 401)
				return
			}
			if _, ok = operators[auth.DID]; !ok {
				writeError(w, 403)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
