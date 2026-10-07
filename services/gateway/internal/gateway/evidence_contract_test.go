package gateway

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestReadinessFlatDependencyContract(t *testing.T) {
	db := fixtureDB(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{}`)) }))
	defer up.Close()
	at := time.Now().UTC()
	valid := at.Add(time.Minute)
	s := Server{DB: db, HTTP: up.Client(), Config: Config{AppViewURL: up.URL}, evidence: Evidence{Service: "gateway", PoolReadiness: "ready", Completeness: "unknown", CheckedAt: &at, ValidUntil: &valid}}
	w := httptest.NewRecorder()
	s.ready(w, httptest.NewRequest("GET", "/readyz", nil))
	var fields map[string]string
	if json.Unmarshal(w.Body.Bytes(), &fields) != nil || w.Code != 200 || fields["projection_pool"] != "ready" || fields["ingestion_observed_at"] == "" || fields["dependencyState"] != "" {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestIngestionCollectorRecordsHTTPFailureAndFutureEvidenceStale(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer up.Close()
	s := Server{Config: Config{ProjectionURL: up.URL}, HTTP: up.Client()}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); s.Collect(ctx) }()
	defer func() { cancel(); <-done }()
	for until := time.Now().Add(time.Second); time.Now().Before(until); {
		e := s.Evidence(time.Now())
		if e.CheckedAt != nil {
			if e.PoolReadiness != "failed_http_503" || e.Completeness != "degraded" {
				t.Fatal(e)
			}
			future := time.Now().Add(time.Hour)
			s.mu.Lock()
			s.evidence.CheckedAt = &future
			s.mu.Unlock()
			if s.Evidence(time.Now()).PoolReadiness != "stale" {
				t.Fatal("future evidence accepted")
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("no sample")
}
func TestFeedModesCaseInsensitiveSourceContract(t *testing.T) {
	c, e := ParseConfig(map[string]string{"WIRE_FEED_MODE": "VISIBLE", "PDS_ATTESTATION_RECEIPT_SECRET": strings.Repeat("s", 32)})
	if e != nil || !c.Serves("wire") {
		t.Fatal(c, e)
	}
}
