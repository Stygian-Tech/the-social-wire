package health

import (
	"net/http"
)

// Controller aggregates independently supervised lane health without flattening away the lane
// that owns a failure. A configured lane must connect to PostgreSQL for startup and become ready
// for aggregate readiness.
type Controller struct {
	lanes map[string]*State
}

func NewController(lanes map[string]*State) *Controller {
	copy := make(map[string]*State, len(lanes))
	for name, state := range lanes {
		copy[name] = state
	}
	return &Controller{lanes: copy}
}

type ControllerSnapshot struct {
	Ready   bool                `json:"ready"`
	Started bool                `json:"started"`
	Lanes   map[string]Snapshot `json:"lanes"`
}

func (c *Controller) Snapshot() ControllerSnapshot {
	laneSnapshots := make(map[string]Snapshot, len(c.lanes))
	started := len(c.lanes) > 0
	ready := len(c.lanes) > 0
	for name, state := range c.lanes {
		snapshot := state.Snapshot()
		laneSnapshots[name] = snapshot
		started = started && snapshot.Database
		ready = ready && snapshot.Ready
	}
	return ControllerSnapshot{Ready: ready, Started: started, Lanes: laneSnapshots}
}

func (c *Controller) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(response http.ResponseWriter, _ *http.Request) {
		writeJSON(response, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("GET /startupz", func(response http.ResponseWriter, _ *http.Request) {
		snapshot := c.Snapshot()
		status := http.StatusOK
		if !snapshot.Started {
			status = http.StatusServiceUnavailable
		}
		writeJSON(response, status, snapshot)
	})
	mux.HandleFunc("GET /readyz", func(response http.ResponseWriter, _ *http.Request) {
		snapshot := c.Snapshot()
		status := http.StatusOK
		if !snapshot.Ready {
			status = http.StatusServiceUnavailable
		}
		writeJSON(response, status, snapshot)
	})
	mux.HandleFunc("GET /status", func(response http.ResponseWriter, _ *http.Request) {
		writeJSON(response, http.StatusOK, c.Snapshot())
	})
	return mux
}
