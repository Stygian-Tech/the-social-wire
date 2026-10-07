package gatewaycore

import "context"

// AuthContext exists only after token authentication or validated internal trust.
type AuthContext struct{ DID, Authorization, DPoP, UpstreamDPoP string }
type authContextKey struct{}

const AnonymousDiscoveryDID = "did:web:thesocialwire.app:anonymous-discovery"

func AuthContextFrom(ctx context.Context) (AuthContext, bool) {
	a, ok := ctx.Value(authContextKey{}).(AuthContext)
	return a, ok
}
func ContextWithAuth(ctx context.Context, auth AuthContext) context.Context {
	return context.WithValue(ctx, authContextKey{}, auth)
}
