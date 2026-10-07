package gateway

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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
	state := map[string]string{"status": status, "service": "gateway", "projection_pool": e.PoolReadiness, "ingestion_completeness": e.Completeness}
	if e.CheckedAt != nil {
		state["ingestion_observed_at"] = e.CheckedAt.UTC().Format(time.RFC3339)
	}
	if e.ValidUntil != nil {
		state["ingestion_valid_until"] = e.ValidUntil.UTC().Format(time.RFC3339)
	}
	writeJSON(w, code, state)
}
func (s *Server) probe(ctx context.Context, base string) bool {
	status, err := s.probeStatus(ctx, base)
	return err == nil && status >= 200 && status < 300
}
func (s *Server) probeStatus(ctx context.Context, base string) (int, error) {
	if base == "" {
		return 0, errors.New("dependency is not configured")
	}
	r, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(base, "/")+"/readyz", nil)
	if err != nil {
		return 0, err
	}
	resp, err := s.HTTP.Do(r)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4097))
	if err != nil {
		return 0, err
	}
	if len(body) > 4096 {
		return 0, errors.New("dependency response exceeds bound")
	}
	return resp.StatusCode, nil
}
func (s *Server) Evidence(now time.Time) Evidence {
	s.mu.RLock()
	e := s.evidence
	s.mu.RUnlock()
	if e.Service == "" {
		e = Evidence{Service: "gateway", PoolReadiness: "not_configured", Freshness: "unknown", Completeness: "unknown"}
	}
	if e.ValidUntil != nil && (!now.Before(*e.ValidUntil) || (e.CheckedAt != nil && e.CheckedAt.After(now))) {
		e.PoolReadiness = "stale"
		e.Completeness = "unknown"
	}
	return e
}
func (s *Server) Collect(ctx context.Context) {
	for {
		e := Evidence{Service: "gateway", PoolReadiness: "not_configured", Freshness: "unknown", Completeness: "unknown"}
		if s.Config.ProjectionURL != "" {
			work, cancel := context.WithTimeout(ctx, 3*time.Second)
			status, err := s.probeStatus(work, s.Config.ProjectionURL)
			cancel()
			if ctx.Err() != nil {
				return
			}
			observed := time.Now().UTC()
			valid := observed.Add(45 * time.Second)
			e.CheckedAt, e.ValidUntil = &observed, &valid
			if err != nil {
				e.PoolReadiness = "unavailable"
				e.Completeness = "degraded"
			} else if status >= 200 && status < 300 {
				e.PoolReadiness = "ready"
			} else {
				e.PoolReadiness = fmt.Sprintf("failed_http_%d", status)
				e.Completeness = "degraded"
			}
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
