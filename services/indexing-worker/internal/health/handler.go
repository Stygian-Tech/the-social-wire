// Package health preserves the consolidated worker's startup, readiness, and
// liveness HTTP contract without exposing database or publisher failures.
package health

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
)

// Probes reports component evidence; liveness never acquires database authority.
type Probes interface {
	Startup(context.Context) error
	Ready(context.Context) error
}

// Handler distinguishes process liveness from complete lane startup/readiness.
// Probe failures use a closed response shape, keeping raw SQL and credentials out.
func Handler(role indexingworkercore.Role, probes Probes) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json; charset=utf-8")
		response.Header().Set("Connection", "close")
		if request.Method != http.MethodGet {
			response.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(response).Encode(map[string]string{"error": "method_not_allowed"})
			return
		}
		status := "live"
		var probe func(context.Context) error
		switch request.URL.Path {
		case "/health", "/livez":
		case "/startupz":
			status, probe = "started", probes.Startup
		case "/readyz":
			status, probe = "ready", probes.Ready
		default:
			response.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(response).Encode(map[string]string{"error": "not_found"})
			return
		}
		responseStatus := http.StatusOK
		if probe != nil {
			probeContext, cancel := context.WithTimeout(request.Context(), 3*time.Second)
			defer cancel()
			if probe(probeContext) != nil {
				responseStatus, status = http.StatusServiceUnavailable, "unavailable"
			}
		}
		response.WriteHeader(responseStatus)
		_ = json.NewEncoder(response).Encode(map[string]string{
			"service": "indexing-worker", "role": string(role), "status": status,
		})
	})
}
