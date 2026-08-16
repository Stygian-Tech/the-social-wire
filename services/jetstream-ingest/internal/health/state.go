package health

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

type State struct {
	mu           sync.RWMutex
	database     bool
	lease        bool
	stream       bool
	paused       bool
	lastSeq      uint64
	lastProgress time.Time
	lastError    string
}

func (s *State) Database(ready bool) { s.mu.Lock(); s.database = ready; s.mu.Unlock() }
func (s *State) Lease(held bool)     { s.mu.Lock(); s.lease = held; s.mu.Unlock() }
func (s *State) Stream(running bool) { s.mu.Lock(); s.stream = running; s.mu.Unlock() }
func (s *State) Paused(paused bool)  { s.mu.Lock(); s.paused = paused; s.mu.Unlock() }
func (s *State) Progress(seq uint64) {
	s.mu.Lock()
	s.lastSeq = seq
	s.lastProgress = time.Now().UTC()
	s.lastError = ""
	s.mu.Unlock()
}
func (s *State) Error(err error) {
	s.mu.Lock()
	if err != nil {
		s.lastError = err.Error()
	}
	s.mu.Unlock()
}

func (s *State) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(response http.ResponseWriter, _ *http.Request) {
		writeJSON(response, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(response http.ResponseWriter, _ *http.Request) {
		snapshot := s.snapshot()
		status := http.StatusOK
		if !snapshot.Ready {
			status = http.StatusServiceUnavailable
		}
		writeJSON(response, status, snapshot)
	})
	mux.HandleFunc("GET /status", func(response http.ResponseWriter, _ *http.Request) {
		writeJSON(response, http.StatusOK, s.snapshot())
	})
	return mux
}

type Snapshot struct {
	Ready        bool      `json:"ready"`
	Database     bool      `json:"database"`
	Lease        bool      `json:"lease"`
	Stream       bool      `json:"stream"`
	Paused       bool      `json:"paused"`
	LastSeq      uint64    `json:"lastSeq"`
	LastProgress time.Time `json:"lastProgress,omitempty"`
	LastError    string    `json:"lastError,omitempty"`
}

func (s *State) snapshot() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Snapshot{
		Ready:    s.database && s.lease && s.stream,
		Database: s.database, Lease: s.lease, Stream: s.stream, Paused: s.paused,
		LastSeq: s.lastSeq, LastProgress: s.lastProgress, LastError: s.lastError,
	}
}

func (s *State) LastProgress() time.Time {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastProgress
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
