package health

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestControllerAggregatesIndependentLaneHealth(t *testing.T) {
	appview := &State{}
	wire := &State{}
	controller := NewController(map[string]*State{"appview": appview, "wire": wire})

	appview.Database(true)
	appview.Lease(true)
	appview.Stream(true)
	wire.Database(true)
	wire.Lease(true)
	wire.Stream(true)

	ready := httptest.NewRecorder()
	controller.Handler().ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if ready.Code != http.StatusOK {
		t.Fatalf("aggregate readiness = %d, want %d", ready.Code, http.StatusOK)
	}

	wire.Stream(false)
	wire.Error(assertionError("wire stopped"))
	failed := httptest.NewRecorder()
	controller.Handler().ServeHTTP(failed, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if failed.Code != http.StatusServiceUnavailable {
		t.Fatalf("degraded readiness = %d, want %d", failed.Code, http.StatusServiceUnavailable)
	}
	var snapshot ControllerSnapshot
	if err := json.NewDecoder(failed.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Started || snapshot.Ready || !snapshot.Lanes["appview"].Ready || snapshot.Lanes["wire"].Ready {
		t.Fatalf("aggregate snapshot = %+v", snapshot)
	}
	if snapshot.Lanes["wire"].LastError != "wire stopped" {
		t.Fatalf("wire failure missing from status: %+v", snapshot.Lanes["wire"])
	}
}

func TestControllerStartupRequiresEveryConfiguredDatabase(t *testing.T) {
	appview := &State{}
	wire := &State{}
	appview.Database(true)
	controller := NewController(map[string]*State{"appview": appview, "wire": wire})

	response := httptest.NewRecorder()
	controller.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/startupz", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("partial startup = %d, want %d", response.Code, http.StatusServiceUnavailable)
	}

	wire.Database(true)
	response = httptest.NewRecorder()
	controller.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/startupz", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("complete startup = %d, want %d", response.Code, http.StatusOK)
	}
}

type assertionError string

func (e assertionError) Error() string { return string(e) }
