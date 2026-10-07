package gateway

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Server struct {
	Config       Config
	DB           *sql.DB
	HTTP, Public *http.Client
	mu           sync.RWMutex
	evidence     Evidence
	Preferences  *Preferences
	Limiter      *RequestLimiter
	Telemetry    *telemetrycore.TelemetryBuffer
	Region       string
	InstanceID   string
}
type Evidence struct {
	Service       string     `json:"service"`
	PoolReadiness string     `json:"poolReadiness"`
	Freshness     string     `json:"freshness"`
	Completeness  string     `json:"completeness"`
	CheckedAt     *time.Time `json:"checkedAt"`
	ValidUntil    *time.Time `json:"validUntil"`
}

func (s *Server) Handler() http.Handler {
	if s.HTTP == nil {
		s.HTTP = &http.Client{Transport: &http.Transport{MaxIdleConns: 64, MaxIdleConnsPerHost: 16, MaxConnsPerHost: 64, IdleConnTimeout: 30 * time.Second}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	if s.Public == nil {
		s.Public = gatewaycore.NewPublicHTTPClient(nil)
	}
	mux := http.NewServeMux()
	auth := gatewaycore.AuthMiddleware(s.Config.Auth, s.Public)
	optional := gatewaycore.OptionalAuthMiddleware(s.Config.Auth, s.Public)
	proxy := &Proxy{s.Config, s.HTTP, s.Public}
	if s.Limiter == nil {
		s.Limiter = &RequestLimiter{}
	}
	for _, route := range Routes {
		if route.Service == "circle" && !s.Config.Serves("circle") {
			continue
		}
		if route.Service == "wire" && !s.Config.Serves("wire") && !s.Config.Serves("finance") && !s.Config.Serves("sports") {
			continue
		}
		h := proxy.Handler(route)
		if route.Service == "wire" || route.Service == "circle" {
			h = s.Limiter.Middleware(h)
		}
		if route.Optional {
			h = optional(h)
		} else if !route.Public {
			h = auth(h)
		}
		mux.Handle(route.Method+" "+route.Path, h)
	}
	for _, path := range []string{"/health", "/livez"} {
		p := path
		mux.HandleFunc("GET "+p, func(w http.ResponseWriter, r *http.Request) {
			status := "ok"
			if p == "/livez" {
				status = "live"
			}
			writeJSON(w, 200, map[string]any{"status": status, "service": "gateway"})
		})
	}
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /freshness", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, s.Evidence(time.Now())) })
	for _, path := range []string{"/oauth-client-metadata.json", "/oauth/client-metadata.json", "/ios-client-metadata.json", "/operations-oauth-client-metadata.json"} {
		mux.HandleFunc("GET "+path, s.metadata)
	}
	if s.Preferences != nil {
		s.Preferences.Register(mux, auth)
	}
	mux.Handle("POST /v1/telemetry/client-performance", auth(http.HandlerFunc(s.performance)))
	return s.requestTrace(s.cors(mux))
}
func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	healthy := s.DB != nil && s.DB.PingContext(ctx) == nil && s.probe(ctx, s.Config.AppViewURL)
	status, code := "ready", 200
	if !healthy {
		status, code = "not_ready", 503
	}
	e := s.Evidence(time.Now())
	writeJSON(w, code, map[string]any{"status": status, "service": "gateway", "dependencyState": map[string]any{"projection_pool": e.PoolReadiness, "ingestion_completeness": e.Completeness, "observed_at": e.CheckedAt, "valid_until": e.ValidUntil}})
}
func (s *Server) probe(ctx context.Context, base string) bool {
	if base == "" {
		return false
	}
	r, e := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(base, "/")+"/readyz", nil)
	if e != nil {
		return false
	}
	resp, e := s.HTTP.Do(r)
	if e != nil {
		return false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4097))
	if err != nil || len(body) > 4096 {
		return false
	}
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}
func (s *Server) Evidence(now time.Time) Evidence {
	s.mu.RLock()
	e := s.evidence
	s.mu.RUnlock()
	if e.Service == "" {
		e = Evidence{Service: "gateway", PoolReadiness: "not_configured", Freshness: "unknown", Completeness: "unknown"}
	}
	if e.ValidUntil != nil && !now.Before(*e.ValidUntil) {
		e.PoolReadiness = "stale"
		e.Completeness = "unknown"
	}
	return e
}
func (s *Server) Collect(ctx context.Context) {
	for {
		e := Evidence{Service: "gateway", PoolReadiness: "not_configured", Freshness: "unknown", Completeness: "unknown"}
		if s.Config.ProjectionURL != "" {
			now := time.Now().UTC()
			valid := now.Add(45 * time.Second)
			e.CheckedAt, e.ValidUntil = &now, &valid
			work, cancel := context.WithTimeout(ctx, 3*time.Second)
			if s.probe(work, s.Config.ProjectionURL) {
				e.PoolReadiness = "ready"
			} else {
				e.PoolReadiness = "unavailable"
				e.Completeness = "degraded"
			}
			cancel()
		}
		s.mu.Lock()
		s.evidence = e
		s.mu.Unlock()
		t := time.NewTimer(15 * time.Second)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func writeError(w http.ResponseWriter, status int, message string) {
	name := map[int]string{400: "InvalidRequest", 401: "AuthRequired", 403: "Forbidden", 404: "NotFound", 413: "InvalidRequest", 429: "RateLimitExceeded", 502: "UpstreamUnavailable", 503: "ServiceUnavailable", 504: "UpstreamTimeout"}[status]
	if name == "" {
		name = "InternalServerError"
	}
	writeJSON(w, status, map[string]string{"error": name, "message": message})
}
