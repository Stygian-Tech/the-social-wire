package gateway

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var tracePattern = regexp.MustCompile(`^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$`)

func randomHex(n int) string {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}

type traceWriter struct {
	http.ResponseWriter
	status   int
	headerAt time.Time
}

func (w *traceWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
		w.headerAt = time.Now()
		w.ResponseWriter.WriteHeader(code)
	}
}
func (w *traceWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	return w.ResponseWriter.Write(b)
}
func (w *traceWriter) Flush() {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (w *traceWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (s *Server) requestTrace(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimSpace(r.Header.Get("X-Request-ID"))
		safe := id != "" && len(id) <= 128
		for _, b := range []byte(id) {
			safe = safe && b >= 0x21 && b <= 0x7e
		}
		if !safe {
			id = randomHex(16)
		}
		traceID := randomHex(16)
		sampled := false
		rate := byte(5)
		if strings.Contains(r.URL.Path, "bootstrap-stream") {
			rate = 10
		}
		random := make([]byte, 1)
		rand.Read(random)
		sampled = random[0]%100 < rate
		if matches := tracePattern.FindStringSubmatch(strings.TrimSpace(r.Header.Get("traceparent"))); matches != nil && matches[1] != strings.Repeat("0", 32) && matches[2] != strings.Repeat("0", 16) {
			traceID = matches[1]
			bits, _ := strconv.ParseUint(matches[3], 16, 8)
			sampled = bits&1 == 1
		}
		flags := "00"
		if sampled {
			flags = "01"
		}
		traceparent := "00-" + traceID + "-" + randomHex(8) + "-" + flags
		r = r.Clone(r.Context())
		r.Header.Set("X-Request-ID", id)
		r.Header.Set("traceparent", traceparent)
		w.Header().Set("X-Request-ID", id)
		w.Header().Set("traceparent", traceparent)
		writer := &traceWriter{ResponseWriter: w}
		at := time.Now()
		defer func() {
			if s.Telemetry == nil {
				return
			}
			status := writer.status
			if status == 0 {
				status = 500
			}
			route := routeTemplate(r.URL.Path)
			dimensions := map[string]string{"service": "gateway", "environment": s.Config.Environment, "deployment_region": normalizedRegion(s.Region), "route_template": route, "method": r.Method, "status_class": fmt.Sprintf("%dxx", status/100)}
			duration := time.Since(at).Seconds()
			if !writer.headerAt.IsZero() {
				duration = writer.headerAt.Sub(at).Seconds()
			}
			if member(r.URL.Path, "/v1/appview/feed", "/xrpc/app.thesocialwire.appview.getFeed", "/v1/appview/entries", "/xrpc/app.thesocialwire.appview.listEntries") {
				kind := "publication"
				if strings.HasSuffix(r.URL.Path, "/feed") || strings.HasSuffix(r.URL.Path, "getFeed") {
					kind = r.URL.Query().Get("kind")
					if !member(kind, "subscribed", "following", "folder", "publication") {
						kind = "invalid"
					}
				}
				dimensions["feed_kind"] = kind
				dimensions["page_kind"] = "first_page"
				if r.URL.Query().Has("cursor") {
					dimensions["page_kind"] = "pagination"
				}
				for _, bound := range []int{50, 100, 150, 250, 500, 1000, 2000, 5000} {
					if duration*1000 <= float64(bound) {
						bucket := map[string]string{}
						for k, v := range dimensions {
							bucket[k] = v
						}
						bucket["le_ms"] = fmt.Sprint(bound)
						s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.appview.feed.duration_bucket", Value: 1, Dimensions: bucket})
					}
				}
			}
			s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.http.server.requests_total", Value: 1, Dimensions: dimensions})
			s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.http.server.duration_seconds", Value: duration, Dimensions: dimensions})
			if sampled || status >= 500 {
				attrs := map[string]string{}
				for k, v := range dimensions {
					attrs[k] = v
				}
				attrs["request_id"] = id
				attrs["deployment_instance"] = s.InstanceID
				state, days := "ok", 7
				if status >= 500 {
					state, days = "error", 30
				}
				s.Telemetry.Enqueue(telemetrycore.MetricSample{Span: &telemetrycore.SpanSample{ID: randomHex(16), Environment: s.Config.Environment, TraceID: traceID, Service: "gateway", Name: "gateway.request", StartedAt: at, DurationMS: duration * 1000, Status: state, Attributes: attrs, ExpiresAt: at.Add(time.Duration(days) * 24 * time.Hour)}})
			}
		}()
		next.ServeHTTP(writer, r)
	})
}
func routeTemplate(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) >= 4 && parts[0] == "v1" && parts[1] == "operations" && member(parts[2], "gaps", "backfills", "alerts", "traces") {
		parts[3] = ":id"
	}
	parts = parts[:min(6, len(parts))]
	for i, v := range parts {
		if len(v) > 48 || strings.HasPrefix(v, "did:") || strings.HasPrefix(v, "at:") {
			parts[i] = ":id"
		}
	}
	value := "/" + strings.Join(parts, "/")
	return value[:min(160, len(value))]
}
func normalizedRegion(value string) string {
	runes := []rune(value)
	safe := []rune{}
	for _, r := range runes {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			safe = append(safe, r)
		}
	}
	if len(safe) == 0 {
		return "unknown"
	}
	return string(safe[:min(32, len(safe))])
}
