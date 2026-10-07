package gateway

import (
	"bytes"
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Proxy struct {
	Config           Config
	Internal, Public *http.Client
}

func (p *Proxy) Handler(route Route) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { p.forward(w, r, route) })
}
func (p *Proxy) forward(w http.ResponseWriter, r *http.Request, route Route) {
	c := p.Config
	base, secret := c.AppViewURL, c.AppViewSecret
	client := p.Internal
	switch route.Service {
	case "operations":
		base, secret = c.OperationsURL, c.OperationsSecret
	case "wire", "circle":
		base = c.AppViewURL
	case "latr":
		base, secret, client = c.LatrURL, "", p.Public
	}
	if base == "" {
		writeError(w, 503, "Upstream service is not configured")
		return
	}
	auth, authenticated := gatewaycore.AuthContextFrom(r.Context())
	if !authenticated && !route.Public && !route.Optional {
		writeError(w, 401, "Authentication required")
		return
	}
	if !authenticated && route.Optional {
		auth.DID = gatewaycore.AnonymousDiscoveryDID
	}
	path := route.Target
	for _, name := range []string{"id", "traceId"} {
		if value := r.PathValue(name); value != "" {
			path = strings.ReplaceAll(path, "{"+name+"}", url.PathEscape(value))
		}
	}
	method := route.UpstreamMethod
	timeout := 60 * time.Second
	if strings.HasSuffix(path, "appview.getFeed") {
		timeout = 3 * time.Second
	}
	media := strings.HasPrefix(path, "/v1/podcasts/") && (strings.HasSuffix(path, "/media") || strings.HasSuffix(path, "/image") || strings.HasSuffix(path, "/assets") || strings.HasSuffix(path, "/public/clips"))
	if media {
		timeout = 6 * time.Hour
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()
	var body io.Reader
	if method != "GET" && method != "HEAD" {
		limit := int64(4 << 20)
		if route.Service == "wire" {
			limit = 4096
		}
		b, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
		if err != nil || int64(len(b)) > limit {
			writeError(w, 413, "Request body exceeds allowed size")
			return
		}
		body = bytes.NewReader(b)
	}
	target := strings.TrimRight(base, "/") + path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	out, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		writeError(w, 502, "Invalid upstream request")
		return
	}
	out.Header.Set("Accept", "application/json")
	if route.Streaming && (!strings.HasSuffix(path, "getReadAgeOptions") || strings.Contains(r.Header.Get("Accept"), "application/x-ndjson")) {
		out.Header.Set("Accept", "application/x-ndjson")
	}
	if body != nil {
		out.Header.Set("Content-Type", "application/json")
	}
	if authenticated {
		out.Header.Set("Authorization", auth.Authorization)
		out.Header.Set("DPoP", auth.DPoP)
		out.Header.Set("X-ATProto-Upstream-DPoP", auth.UpstreamDPoP)
	}
	for _, h := range []string{"X-Request-ID", "traceparent", "Idempotency-Key", "Last-Event-ID", "Range", "X-Wire-Moderation-DPoP", "X-Circle-Graph-DPoP"} {
		if v := r.Header.Get(h); v != "" {
			out.Header.Set(h, v)
		}
	}
	if !authenticated && route.Optional {
		if v := r.Header.Get("If-None-Match"); v != "" {
			out.Header.Set("If-None-Match", v)
		}
	}
	out.Header.Set("X-Forwarded-Host", r.Host)
	proto := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0])
	if proto == "" {
		proto = "https"
	}
	out.Header.Set("X-Forwarded-Proto", proto)
	if secret != "" && auth.DID != "" {
		headers, e := gatewaycore.SignedInternalHeaders(secret, method, path, auth.DID, time.Now())
		if e != nil {
			writeError(w, 502, "Unable to sign upstream request")
			return
		}
		for k, v := range headers {
			out.Header[k] = v
		}
	}
	if route.Service == "latr" {
		if c.LatrClientID == "" || (c.LatrAPIKey == "" && c.LatrCredential == "") {
			writeError(w, 503, "L@tr official client credentials are not configured")
			return
		}
		proof := strings.TrimSpace(r.Header.Get("X-Latr-Gateway-DPoP"))
		if proof == "" {
			writeError(w, 400, "X-Latr-Gateway-DPoP is required")
			return
		}
		out.Header.Set("DPoP", proof)
		out.Header.Set("X-Latr-Client-Id", c.LatrClientID)
		if c.LatrAPIKey != "" {
			out.Header.Set("X-Latr-API-Key", c.LatrAPIKey)
		} else {
			out.Header.Set("X-Latr-Official-Client", c.LatrCredential)
		}
	}
	reply, err := client.Do(out)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			writeError(w, 504, "Upstream request timed out")
		} else {
			writeError(w, 502, "Upstream service unavailable")
		}
		return
	}
	defer reply.Body.Close()
	for _, h := range []string{"Content-Type", "ETag", "Cache-Control", "DPoP-Nonce", "X-Request-ID", "traceparent", "Server-Timing", "X-AppView-Feed-Source", "X-AppView-Membership-Updated-At", "Content-Range", "Accept-Ranges", "X-Content-Type-Options", "Retry-After"} {
		if v := reply.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	streaming := media || strings.Contains(path, "events/stream") || strings.Contains(path, "bootstrap-stream") || (strings.HasSuffix(path, "getReadAgeOptions") && strings.Contains(r.Header.Get("Accept"), "application/x-ndjson"))
	if media || path == "/v1/podcasts/search" {
		w.Header().Set("Cache-Control", "private, no-store")
	}
	if streaming {
		w.WriteHeader(reply.StatusCode)
		buf := make([]byte, 32<<10)
		for {
			n, e := reply.Body.Read(buf)
			if n > 0 {
				if _, err = w.Write(buf[:n]); err != nil {
					return
				}
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
			if e != nil {
				if e != io.EOF {
					panic(http.ErrAbortHandler)
				}
				return
			}
		}
	}
	b, e := io.ReadAll(io.LimitReader(reply.Body, (8<<20)+1))
	if e != nil || len(b) > 8<<20 {
		writeError(w, 502, "Invalid upstream response")
		return
	}
	w.WriteHeader(reply.StatusCode)
	_, _ = w.Write(b)
}
