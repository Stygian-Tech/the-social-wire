package gateway

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPerformanceRejectsAbsentDurationAndQueuesOnlyBoundedDimensions(t *testing.T) {
	var captured []telemetrycore.MetricSample
	buffer := &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, s []telemetrycore.MetricSample) error {
		captured = append(captured, s...)
		return nil
	}}
	s := Server{Config: Config{Environment: "dev"}, Telemetry: buffer}
	for _, duration := range []string{"", `,"durationMs":null`, `,"durationMs":-1`, `,"durationMs":70000`, `,"durationMs":50`} {
		body := `{"event":"feed_switch","feedType":"aggregate","cacheState":"hit","outcome":"success","environment":"production"` + duration + `}`
		r := httptest.NewRequest("POST", "https://gateway.invalid/v1/telemetry/client-performance", strings.NewReader(body))
		w := httptest.NewRecorder()
		s.performance(w, r)
		want := 400
		if duration == `,"durationMs":50` {
			want = 202
		}
		if w.Code != want {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	buffer.Flush(context.Background())
	if len(captured) != 9 || captured[0].Dimensions["environment"] != "dev" {
		t.Fatal(captured)
	}
}
func TestRequestTracePreservesParentIdentityAndSanitizesRoute(t *testing.T) {
	var samples []telemetrycore.MetricSample
	s := Server{Config: Config{Environment: "dev"}, Telemetry: &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, b []telemetrycore.MetricSample) error { samples = b; return nil }}}
	h := s.requestTrace(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("traceparent"), "00-11111111111111111111111111111111-") {
			t.Error("trace identity lost")
		}
		w.WriteHeader(200)
	}))
	r := httptest.NewRequest("GET", "https://gateway.invalid/v1/operations/gaps/private/investigation?token=secret", nil)
	r.Header.Set("traceparent", "00-11111111111111111111111111111111-2222222222222222-01")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Header().Get("X-Request-ID") == "" {
		t.Fatal("missing request ID")
	}
	s.Telemetry.Flush(context.Background())
	if len(samples) != 3 || samples[2].Span == nil || samples[2].Span.Attributes["route_template"] != "/v1/operations/gaps/:id/investigation" {
		t.Fatal(samples)
	}
	raw, _ := json.Marshal(samples)
	if strings.Contains(string(raw), "private") || strings.Contains(string(raw), "secret") {
		t.Fatal("private request data in telemetry")
	}
}
func TestPostgresSampledSpanPersists(t *testing.T) {
	db := fixtureDB(t)
	id := "gateway-fixture-span"
	t.Cleanup(func() { db.Exec(`DELETE FROM operations_trace_spans WHERE id=$1`, id) })
	exporter := telemetrycore.PostgresExporter{DB: db, Environment: "dev"}
	at := time.Now().UTC()
	span := &telemetrycore.SpanSample{ID: id, Environment: "dev", TraceID: strings.Repeat("1", 32), Service: "gateway", Name: "gateway.request", StartedAt: at, DurationMS: 12, Status: "ok", Attributes: map[string]string{"route_template": "/v1/appview/feed", "token": "must-drop"}, ExpiresAt: at.Add(7 * 24 * time.Hour)}
	if e := exporter.Export(context.Background(), []telemetrycore.MetricSample{{Span: span}}); e != nil {
		t.Fatal(e)
	}
	var attrs string
	if e := db.QueryRow(`SELECT attributes::text FROM operations_trace_spans WHERE id=$1`, id).Scan(&attrs); e != nil || strings.Contains(attrs, "must-drop") {
		t.Fatal(attrs, e)
	}
}
