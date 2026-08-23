package health

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
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

func TestCompletedSnapshotRemainsReadyWithoutALiveStream(t *testing.T) {
	state := &State{}
	state.Database(true)
	state.Lease(true)
	state.SnapshotComplete(200)

	response := httptest.NewRecorder()
	state.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("completed snapshot readiness = %d, want %d", response.Code, http.StatusOK)
	}
	var snapshot Snapshot
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Ready || !snapshot.SnapshotDone || snapshot.Stream || snapshot.LastSeq != 200 {
		t.Fatalf("completed snapshot status = %+v", snapshot)
	}
}

func TestBackpressureFailsReadinessAndReportsCapacity(t *testing.T) {
	state := &State{}
	state.Database(true)
	state.Lease(true)
	state.Stream(true)
	state.Backpressure(true, 21, 20, 81, 80)

	response := httptest.NewRecorder()
	state.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("backpressured readiness = %d", response.Code)
	}
	var snapshot Snapshot
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Backpressured || snapshot.InboxRows != 21 || snapshot.DatabaseMaxBytes != 80 {
		t.Fatalf("capacity snapshot = %+v", snapshot)
	}
}

func TestAdmissionPacingIsVisibleWithoutFailingReadiness(t *testing.T) {
	state := &State{}
	state.Database(true)
	state.Lease(true)
	state.Stream(true)
	state.AdmissionLimit(1.5, 2)
	state.AdmissionPacing(true, 250*time.Millisecond)

	response := httptest.NewRecorder()
	state.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/status", nil))
	var snapshot Snapshot
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Ready || !snapshot.AdmissionRateLimited {
		t.Fatalf("pacing snapshot=%+v", snapshot)
	}
	if snapshot.AdmissionRateLimit != 1.5 || snapshot.AdmissionBurstLimit != 2 || snapshot.AdmissionWaitMilliseconds != 250 {
		t.Fatalf("pacing limits=%+v", snapshot)
	}
	if snapshot.AdmissionWaitUntil.IsZero() {
		t.Fatal("missing admission wait deadline")
	}
}
