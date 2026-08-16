package health

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthAndReadinessEndpoints(t *testing.T) {
	state := &State{}
	handler := state.Handler()

	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if health.Code != http.StatusOK {
		t.Fatalf("health status = %d, want %d", health.Code, http.StatusOK)
	}
	if health.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("health content type = %q", health.Header().Get("Content-Type"))
	}

	notStarted := httptest.NewRecorder()
	handler.ServeHTTP(notStarted, httptest.NewRequest(http.MethodGet, "/startupz", nil))
	if notStarted.Code != http.StatusServiceUnavailable {
		t.Fatalf("initial startup = %d, want %d", notStarted.Code, http.StatusServiceUnavailable)
	}

	notReady := httptest.NewRecorder()
	handler.ServeHTTP(notReady, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if notReady.Code != http.StatusServiceUnavailable {
		t.Fatalf("initial readiness = %d, want %d", notReady.Code, http.StatusServiceUnavailable)
	}

	state.Database(true)
	started := httptest.NewRecorder()
	handler.ServeHTTP(started, httptest.NewRequest(http.MethodGet, "/startupz", nil))
	if started.Code != http.StatusOK {
		t.Fatalf("database startup = %d, want %d", started.Code, http.StatusOK)
	}

	state.Lease(true)
	state.Stream(true)
	ready := httptest.NewRecorder()
	handler.ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if ready.Code != http.StatusOK {
		t.Fatalf("ready status = %d, want %d", ready.Code, http.StatusOK)
	}
	var snapshot Snapshot
	if err := json.NewDecoder(ready.Body).Decode(&snapshot); err != nil {
		t.Fatalf("decode readiness: %v", err)
	}
	if !snapshot.Ready || !snapshot.Database || !snapshot.Lease || !snapshot.Stream {
		t.Fatalf("unexpected ready snapshot: %+v", snapshot)
	}
}

func TestStatusTracksPauseProgressAndErrors(t *testing.T) {
	state := &State{}
	state.Paused(true)
	state.Error(errors.New("temporary stream failure"))

	errorStatus := httptest.NewRecorder()
	state.Handler().ServeHTTP(
		errorStatus,
		httptest.NewRequest(http.MethodGet, "/status", nil),
	)
	var failed Snapshot
	if err := json.NewDecoder(errorStatus.Body).Decode(&failed); err != nil {
		t.Fatalf("decode failed status: %v", err)
	}
	if !failed.Paused || failed.LastError != "temporary stream failure" {
		t.Fatalf("unexpected failed snapshot: %+v", failed)
	}

	state.Progress(42)
	if state.LastProgress().IsZero() {
		t.Fatal("progress timestamp was not recorded")
	}
	progressStatus := httptest.NewRecorder()
	state.Handler().ServeHTTP(
		progressStatus,
		httptest.NewRequest(http.MethodGet, "/status", nil),
	)
	var progressed Snapshot
	if err := json.NewDecoder(progressStatus.Body).Decode(&progressed); err != nil {
		t.Fatalf("decode progress status: %v", err)
	}
	if progressed.LastSeq != 42 || progressed.LastProgress.IsZero() || progressed.LastError != "" {
		t.Fatalf("unexpected progress snapshot: %+v", progressed)
	}
}
