package gateway

import (
	"net/http"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type subscriptionEntitlements struct {
	ViewerDID string `json:"viewerDid"`
	Plan      string `json:"plan"`
}

// Pro grants are server-owned until the billing integration supplies entitlements.
// Never accept a plan or viewer identity from request parameters or headers.
func (c Config) hasPro(did string) bool {
	return did != "" && did != gatewaycore.AnonymousDiscoveryDID && c.ProDIDs[did]
}

func (s *Server) subscriptionEntitlements(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return
	}
	plan := "free"
	if s.Config.hasPro(auth.DID) {
		plan = "pro"
	}
	writeJSON(w, http.StatusOK, subscriptionEntitlements{ViewerDID: auth.DID, Plan: plan})
}

func requirePro(w http.ResponseWriter, r *http.Request, config Config) bool {
	w.Header().Set("Cache-Control", "private, no-store")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		writeError(w, http.StatusUnauthorized, "Authentication required")
		return false
	}
	if config.ProGatingEnabled && !config.hasPro(auth.DID) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "ProRequired", "message": "A Pro subscription is required"})
		return false
	}
	return true
}
