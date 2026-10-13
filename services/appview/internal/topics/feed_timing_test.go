package topics

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

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
