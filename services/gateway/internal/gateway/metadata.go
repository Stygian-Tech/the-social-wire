package gateway

import (
	"net/http"
	"net/url"
	"strings"
)

func (s *Server) metadata(w http.ResponseWriter, r *http.Request) {
	origin := strings.TrimSuffix(s.Config.PublicOrigin, "/")
	if origin == "" {
		origin = strings.TrimSuffix(gatewayOrigin(r), "/")
	}
	clientOrigin := origin
	path := "/oauth-client-metadata.json"
	redirect := origin + "/callback"
	scope, kind, name := webScope, "web", "The Social Wire"
	switch r.URL.Path {
	case "/ios-client-metadata.json":
		path = r.URL.Path
		kind, scope = "native", iosScope
		clientOrigin = strings.TrimSuffix(s.Config.IOSOrigin, "/")
		if clientOrigin == "" {
			clientOrigin = gatewayOrigin(r)
		}
		u, e := url.Parse(clientOrigin)
		if e != nil || u.Hostname() == "" {
			writeError(w, 400, "Invalid metadata origin")
			return
		}
		parts := strings.Split(u.Hostname(), ".")
		for i, j := 0, len(parts)-1; i < j; i, j = i+1, j-1 {
			parts[i], parts[j] = parts[j], parts[i]
		}
		redirect = strings.Join(parts, ".") + ":/oauth/callback"
	case "/operations-oauth-client-metadata.json":
		path = r.URL.Path
		clientOrigin = gatewayOrigin(r)
		scope, name = "atproto", "The Social Wire Operations"
		redirect = strings.TrimSuffix(s.Config.OperationsOrigin, "/") + "/callback"
		if s.Config.OperationsOrigin == "" {
			writeError(w, 503, "Operations OAuth origin is not configured")
			return
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	writeJSON(w, 200, map[string]any{"client_id": clientOrigin + path, "application_type": kind, "grant_types": []string{"authorization_code", "refresh_token"}, "response_types": []string{"code"}, "redirect_uris": []string{redirect}, "scope": scope, "token_endpoint_auth_method": "none", "dpop_bound_access_tokens": true, "client_name": name, "client_uri": clientOrigin})
}
func gatewayOrigin(r *http.Request) string { htu := gatewaycoreOrigin(r); return htu }
func gatewaycoreOrigin(r *http.Request) string {
	proto := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0])
	if proto == "" {
		proto = "https"
	}
	return proto + "://" + r.Host
}
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := false
		for _, o := range s.Config.AllowedOrigins {
			if origin == o && origin != "" {
				allowed = true
				break
			}
		}
		if allowed {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Add("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Accept, Authorization, Content-Type, Origin, If-None-Match, DPoP, X-Request-ID, traceparent, Idempotency-Key, Last-Event-ID, X-ATProto-Upstream-DPoP, X-ATProto-Session-DPoP, X-ATProto-Session-Receipt, X-ATProto-Session-Receipt-Required, X-ATProto-Upstream-DPoP-Prepared, X-Latr-Gateway-DPoP, X-Wire-Moderation-DPoP, X-Circle-Graph-DPoP")
			w.Header().Set("Access-Control-Expose-Headers", "X-ATProto-Session-DPoP-Nonce, X-ATProto-Session-Receipt, X-ATProto-Session-Receipt-Required, X-ATProto-Upstream-DPoP-Prepared")
			w.Header().Set("Access-Control-Max-Age", "3600")
		}
		if r.Method == "OPTIONS" {
			if !allowed {
				writeError(w, 403, "Origin is not allowed")
				return
			}
			w.WriteHeader(204)
			return
		}
		next.ServeHTTP(w, r)
	})
}
