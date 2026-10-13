package topics

import (
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
)

type feedTimingWriter struct {
	http.ResponseWriter
	mu      sync.Mutex
	phases  map[string]time.Duration
	status  int
	closed  bool
	started time.Time
}

func (w *feedTimingWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *feedTimingWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.mu.Lock()
	keys := make([]string, 0, len(w.phases))
	for key := range w.phases {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	timings := []string{fmt.Sprintf("feed;dur=%.3f", float64(time.Since(w.started))/float64(time.Millisecond))}
	for _, key := range keys {
		timings = append(timings, fmt.Sprintf("%s;dur=%.3f", key, float64(w.phases[key])/float64(time.Millisecond)))
	}
	w.mu.Unlock()
	w.Header().Add("Server-Timing", strings.Join(timings, ", "))
	w.ResponseWriter.WriteHeader(status)
}
func (w *feedTimingWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}

func isFeedTimingPhase(phase string) bool {
	switch phase {
	case "snapshot-query", "snapshot-cache-hit", "snapshot-cache-miss", "snapshot-decode", "source-generation-cache-hit", "source-generation-cache-miss", "source-catalog-cache-hit", "source-catalog-cache-miss", "catalog-cache-hit", "catalog-cache-miss", "serialization", "moderation", "source", "source-transport", "source-decode", "catalog", "catalog-query-open", "catalog-scan", "catalog-decode", "catalog-revision", "selections", "snapshot-lookup", "snapshot-load", "snapshot-persistence", "rehydration", "analysis", "db-acquisition", "db-query":
		return true
	}
	return false
}

func (r Routes) observeFeed(feed string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		started := time.Now()
		writer := &feedTimingWriter{ResponseWriter: w, phases: map[string]time.Duration{}, started: started}
		_, viewer := auth(req)
		dims := map[string]string{"feed": feed, "auth": "public", "page": "first"}
		if viewer != "" {
			dims["auth"] = "viewer"
		}
		if req.URL.Query().Get("cursor") != "" {
			dims["page"] = "continuation"
		}
		authMode, pageMode := dims["auth"], dims["page"]
		ctx := topicreadcore.WithFeedPhaseObserver(req.Context(), func(phase string, elapsed time.Duration) {
			if !isFeedTimingPhase(phase) {
				return
			}
			writer.mu.Lock()
			if writer.closed {
				writer.mu.Unlock()
				return
			}
			writer.phases[phase] += elapsed
			writer.mu.Unlock()
			if r.Telemetry != nil {
				phaseDims := map[string]string{"feed": feed, "auth": authMode, "page": pageMode, "phase": phase}
				r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "feed.phase.latency_ms", Value: float64(elapsed) / float64(time.Millisecond), Dimensions: phaseDims, At: r.now()})
			}
		})
		ctx = corpuscore.WithSourceRequestID(ctx, req.Header.Get("X-Request-ID"))
		next(writer, req.WithContext(ctx))
		writer.mu.Lock()
		writer.closed = true
		writer.mu.Unlock()
		if writer.status == 0 {
			writer.WriteHeader(http.StatusOK)
		}
		dims["status"] = fmt.Sprint(writer.status)
		elapsed := time.Since(started)
		if r.Telemetry != nil {
			r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "feed.endpoint.latency_ms", Value: float64(elapsed) / float64(time.Millisecond), Dimensions: dims, At: r.now()})
		}
		slog.Info("Feed request completed", "request_id", w.Header().Get("X-Request-ID"), "feed", feed, "auth", dims["auth"], "page", dims["page"], "status", writer.status, "duration_ms", elapsed.Milliseconds())
	}
}
