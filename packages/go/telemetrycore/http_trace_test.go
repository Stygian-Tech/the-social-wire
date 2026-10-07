package telemetrycore

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHTTPTracePreservesSampledContextAndBoundsIdentityCardinality(t *testing.T) {
	buffer := &TelemetryBuffer{}
	incoming := "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
	seenID, seenTrace := "", ""
	handler := HTTPTrace(HTTPTraceConfig{Service: "operations", Environment: "dev", InstanceID: "instance", Region: "sfo<script>", Telemetry: buffer}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenID = r.Header.Get("X-Request-ID")
		seenTrace = r.Header.Get("traceparent")
		w.WriteHeader(200)
		_, _ = io.WriteString(w, "ok")
	}))
	request := httptest.NewRequest("GET", "/v1/operations/gaps/did:plc:private/investigation?private=secret", nil)
	request.Header.Set("X-Request-ID", " safe-id ")
	request.Header.Set("traceparent", incoming)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if seenID != "safe-id" || seenTrace == incoming || !strings.HasPrefix(seenTrace, "00-0123456789abcdef0123456789abcdef-") || !strings.HasSuffix(seenTrace, "-01") || response.Header().Get("traceparent") != seenTrace {
		t.Fatal(seenID, seenTrace, response.Header())
	}
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	if len(buffer.queue) != 3 {
		t.Fatal(len(buffer.queue))
	}
	span := buffer.queue[2].sample.Span
	if span == nil || span.Service != "operations" || span.Name != "operations.request" || span.Attributes["route_template"] != "/v1/operations/gaps/:id/investigation" || span.Attributes["deployment_region"] != "sfoscript" || span.Attributes["request_id"] != "safe-id" {
		t.Fatal(span)
	}
	for _, sample := range buffer.queue {
		for _, value := range sample.sample.Dimensions {
			if strings.Contains(value, "private") || strings.Contains(value, "secret") {
				t.Fatal(sample)
			}
		}
	}
}
func TestHTTPTraceRecordsUnsampledErrorsAndStreamHeaderLatency(t *testing.T) {
	buffer := &TelemetryBuffer{}
	handler := HTTPTrace(HTTPTraceConfig{Service: "operations", Environment: "dev", Telemetry: buffer}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		w.(http.Flusher).Flush()
		time.Sleep(20 * time.Millisecond)
	}))
	request := httptest.NewRequest("GET", "/v1/operations/events/stream", nil)
	request.Header.Set("traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-00")
	request.Header.Set("X-Request-ID", strings.Repeat("x", 129))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if len(response.Header().Get("X-Request-ID")) != 32 {
		t.Fatal(response.Header())
	}
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	if len(buffer.queue) != 3 || buffer.queue[2].sample.Span == nil || buffer.queue[2].sample.Span.Status != "error" || buffer.queue[2].sample.Span.DurationMS >= 15 {
		t.Fatal(buffer.queue)
	}
}
