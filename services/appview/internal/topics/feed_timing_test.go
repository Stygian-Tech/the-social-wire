package topics

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
)

func TestFeedTimingAccumulatesPhasesAndPreservesErrorResponse(t *testing.T) {
	handler := Routes{}.observeFeed("finance", func(w http.ResponseWriter, req *http.Request) {
		topicreadcore.ObserveFeedPhase(req.Context(), "rehydration", 2*time.Millisecond)
		topicreadcore.ObserveFeedPhase(req.Context(), "rehydration", 3*time.Millisecond)
		fail(w, topicreadcore.ErrUpstreamProofRequired)
	})
	w := httptest.NewRecorder()
	handler(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getFinance?cursor=private-value", nil))
	if w.Code != 428 || !strings.Contains(w.Body.String(), `"error":"UpstreamProofRequired"`) {
		t.Fatal(w.Code, w.Body.String())
	}
	value := w.Header().Get("Server-Timing")
	if !strings.Contains(value, "rehydration;dur=5.000") || !strings.Contains(value, "feed;dur=") || strings.Contains(value, "private-value") {
		t.Fatal(value)
	}
}

func TestFeedTimingImplicitSuccessAndExistingTiming(t *testing.T) {
	handler := Routes{}.observeFeed("wire", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Add("Server-Timing", "auth;dur=1")
		_, _ = w.Write([]byte(`{"items":[]}`))
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	w := httptest.NewRecorder()
	handler(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 200 || len(w.Header().Values("Server-Timing")) != 2 {
		t.Fatal(w.Code, w.Header())
	}
}

func TestFeedTimingIgnoresCallbacksAfterRequestCompletion(t *testing.T) {
	var ctx context.Context
	var writer *feedTimingWriter
	handler := Routes{}.observeFeed("wire", func(w http.ResponseWriter, req *http.Request) {
		ctx, writer = req.Context(), w.(*feedTimingWriter)
	})
	handler(httptest.NewRecorder(), httptest.NewRequest("GET", "/", nil))
	var group sync.WaitGroup
	for range 100 {
		group.Go(func() { topicreadcore.ObserveFeedPhase(ctx, "analysis", time.Millisecond) })
	}
	group.Wait()
	if len(writer.phases) != 0 {
		t.Fatal("completed request must not retain detached timings", writer.phases)
	}
}

func TestFeedTimingAcceptsFixedSourceAndCatalogPhasesOnly(t *testing.T) {
	handler := Routes{}.observeFeed("sports", func(w http.ResponseWriter, req *http.Request) {
		for _, phase := range []string{"source-transport", "source-decode", "catalog-scan", "catalog-decode", "catalog-revision", "snapshot-lookup"} {
			topicreadcore.ObserveFeedPhase(req.Context(), phase, time.Millisecond)
		}
		topicreadcore.ObserveFeedPhase(req.Context(), "viewer-private-identifier", time.Second)
		w.WriteHeader(200)
	})
	writer := httptest.NewRecorder()
	handler(writer, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getSports", nil))
	timings := writer.Header().Get("Server-Timing")
	for _, phase := range []string{"source-transport", "source-decode", "catalog-scan", "catalog-decode", "catalog-revision", "snapshot-lookup"} {
		if !strings.Contains(timings, phase+";dur=1.000") {
			t.Fatal(phase, timings)
		}
	}
	if strings.Contains(timings, "viewer-private") {
		t.Fatal(timings)
	}
}

func TestFeedTimingPropagatesBoundedSourceCorrelation(t *testing.T) {
	for _, id := range []string{"request-123", "did:plc:viewer", strings.Repeat("a", 129)} {
		handler := Routes{}.observeFeed("sports", func(w http.ResponseWriter, req *http.Request) {
			if got := corpuscore.SourceRequestID(req.Context()); got != corpuscore.ValidSourceRequestID(id) {
				t.Fatal(got)
			}
		})
		req := httptest.NewRequest("GET", "/", nil)
		req.Header.Set("X-Request-ID", id)
		handler(httptest.NewRecorder(), req)
	}
}

func TestRealTopicResponseReportsSerializationHeaderAndMetric(t *testing.T) {
	for _, status := range []int{200, 304} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			var samples []telemetrycore.MetricSample
			buffer := &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, batch []telemetrycore.MetricSample) error {
				samples = append(samples, batch...)
				return nil
			}}
			handler := (Routes{Telemetry: buffer}).observeFeed("sports", func(w http.ResponseWriter, req *http.Request) {
				if err := response(w, req, map[string]any{"items": []string{"rendered"}}, "etag", false, "generation", "ranked"); err != nil {
					t.Fatal(err)
				}
			})
			req := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getSports", nil)
			if status == 304 {
				req.Header.Set("If-None-Match", "etag")
			}
			writer := httptest.NewRecorder()
			handler(writer, req)
			if writer.Code != status || !strings.Contains(writer.Header().Get("Server-Timing"), "serialization;dur=") {
				t.Fatal(writer.Code, writer.Header())
			}
			if status == 200 && !strings.Contains(writer.Body.String(), "rendered") {
				t.Fatal(writer.Body.String())
			}
			if status == 304 && writer.Body.Len() != 0 {
				t.Fatal("304 has body")
			}
			if _, err := buffer.Flush(context.Background()); err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, sample := range samples {
				if sample.Name == "feed.phase.latency_ms" && sample.Dimensions["phase"] == "serialization" {
					count++
					if sample.Value < 0 || sample.Dimensions["feed"] != "sports" || sample.Dimensions["auth"] != "public" || sample.Dimensions["page"] != "first" {
						t.Fatal(sample)
					}
				}
			}
			if count != 1 {
				t.Fatal("expected one real serialization metric", samples)
			}
		})
	}
}
