package gateway

import (
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/navigationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode"
)

type ClientPerformance struct {
	Event       string   `json:"event"`
	Tab         string   `json:"tab,omitempty"`
	DurationMS  *float64 `json:"durationMs"`
	FeedType    string   `json:"feedType"`
	CacheState  string   `json:"cacheState"`
	Outcome     string   `json:"outcome"`
	Environment string   `json:"environment"`
}

func (s *Server) performance(w http.ResponseWriter, r *http.Request) {
	var b ClientPerformance
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&b) != nil {
		writeError(w, 400, "Invalid client performance sample")
		return
	}
	if b.Event == "tab_open" || b.Event == "tab_dwell" {
		s.navigation(w, r, b)
		return
	}
	if !member(b.Event, "cached_feed_paint", "uncached_feed_paint", "feed_switch", "fresh_merge", "feed_error") || b.DurationMS == nil || math.IsNaN(*b.DurationMS) || math.IsInf(*b.DurationMS, 0) || *b.DurationMS < 0 || *b.DurationMS > 60000 || !member(b.FeedType, "aggregate", "publication") || !member(b.CacheState, "hit", "miss") || !member(b.Outcome, "success", "error") || !member(b.Environment, "local", "dev", "test", "production") {
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

func (s *Server) navigation(w http.ResponseWriter, r *http.Request, b ClientPerformance) {
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		writeError(w, 401, "Authentication required")
		return
	}
	if !navigationcore.ValidTab(b.Tab) || b.DurationMS == nil || math.IsNaN(*b.DurationMS) || math.IsInf(*b.DurationMS, 0) || *b.DurationMS < 0 || *b.DurationMS > 60000 || (b.Event == "tab_open" && *b.DurationMS != 0) || (b.Event == "tab_dwell" && *b.DurationMS == 0) || !member(b.Environment, "local", "dev", "test", "production") {
		writeError(w, 400, "Invalid tab usage sample")
		return
	}
	if s.Telemetry == nil {
		w.WriteHeader(202)
		return
	}
	if err := navigationcore.Record(r.Context(), s.DB, s.Config.OperationsSecret, s.Config.Environment, auth.DID, b.Tab, b.Event, *b.DurationMS, time.Now()); err != nil {
		writeError(w, 503, "Tab usage recording unavailable")
		return
	}
	name, value := "socialwire.navigation.tab.opens_total", float64(1)
	if b.Event == "tab_dwell" {
		name = "socialwire.navigation.tab.dwell_ms"
		value = *b.DurationMS
	}
	s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: name, Value: value, Dimensions: map[string]string{"tab": b.Tab, "environment": s.Config.Environment}})
	w.WriteHeader(202)
}
