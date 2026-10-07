package gateway

import (
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"math"
	"net/http"
	"strings"
	"unicode"
)

type ClientPerformance struct {
	Event       string   `json:"event"`
	DurationMS  *float64 `json:"durationMs"`
	FeedType    string   `json:"feedType"`
	CacheState  string   `json:"cacheState"`
	Outcome     string   `json:"outcome"`
	Environment string   `json:"environment"`
}

func (s *Server) performance(w http.ResponseWriter, r *http.Request) {
	var b ClientPerformance
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&b) != nil || !member(b.Event, "cached_feed_paint", "uncached_feed_paint", "feed_switch", "fresh_merge", "feed_error") || b.DurationMS == nil || math.IsNaN(*b.DurationMS) || math.IsInf(*b.DurationMS, 0) || *b.DurationMS < 0 || *b.DurationMS > 60000 || !member(b.FeedType, "aggregate", "publication") || !member(b.CacheState, "hit", "miss") || !member(b.Outcome, "success", "error") || !member(b.Environment, "local", "dev", "test", "production") {
		writeError(w, 400, "Invalid client performance sample")
		return
	}
	if s.Telemetry != nil {
		region := strings.Map(func(r rune) rune {
			if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' {
				return r
			}
			return -1
		}, s.Region)
		if region == "" {
			region = "unknown"
		}
		runes := []rune(region)
		region = string(runes[:min(32, len(runes))])
		dims := map[string]string{"event": b.Event, "feed_type": b.FeedType, "cache_state": b.CacheState, "outcome": b.Outcome, "environment": s.Config.Environment, "deployment_region": region}
		s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.reader.client.duration_ms", Value: *b.DurationMS, Dimensions: dims})
		for _, bound := range []int{50, 100, 150, 250, 500, 1000, 2000, 5000} {
			if *b.DurationMS <= float64(bound) {
				bucket := map[string]string{}
				for k, v := range dims {
					bucket[k] = v
				}
				bucket["le_ms"] = fmt.Sprint(bound)
				s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.reader.client.duration_bucket", Value: 1, Dimensions: bucket})
			}
		}
	}
	w.WriteHeader(202)
}
func member(v string, values ...string) bool {
	for _, value := range values {
		if v == value {
			return true
		}
	}
	return false
}
