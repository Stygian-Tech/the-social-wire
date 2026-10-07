package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestGatewayHeartbeatPublishesFreshBoundedEvidenceAndHealthMetrics(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	instance := fmt.Sprintf("gateway-heartbeat-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		db.Exec(`DELETE FROM operations_service_state WHERE service='gateway' AND environment='dev' AND instance_id=$1`, instance)
	})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer up.Close()
	now := time.Now()
	valid := now.Add(time.Minute)
	var samples []telemetrycore.MetricSample
	buffer := &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, b []telemetrycore.MetricSample) error {
		samples = append(samples, b...)
		return nil
	}}
	s := Server{DB: db, HTTP: up.Client(), Telemetry: buffer, Config: Config{Environment: "dev", AppViewURL: up.URL}, evidence: Evidence{Service: "gateway", PoolReadiness: "ready", Completeness: "healthy", CheckedAt: &now, ValidUntil: &valid}}
	if err := s.heartbeatOnce(ctx, instance, "exact-deployment", now); err != nil {
		t.Fatal(err)
	}
	var live, ready, complete, version string
	var raw []byte
	if err := db.QueryRow(`SELECT liveness,readiness,completeness,dependency_state::text,version FROM operations_service_state WHERE service='gateway' AND environment='dev' AND instance_id=$1`, instance).Scan(&live, &ready, &complete, &raw, &version); err != nil {
		t.Fatal(err)
	}
	var deps map[string]string
	if err := json.Unmarshal(raw, &deps); err != nil {
		t.Fatal(err)
	}
	if live != "degraded" || ready != "degraded" || complete != "degraded" || version != "exact-deployment" || deps["appview"] != "failed_http_503" || deps["operations_database"] != "ready" || deps["telemetry_exporter"] != "idle_no_export_yet" {
		t.Fatal(live, ready, complete, version, deps)
	}
	if _, err := buffer.Flush(ctx); err != nil || len(samples) != 4 {
		t.Fatal("health sample emission", err, len(samples))
	}
	s.mu.Lock()
	short := now.Add(10 * time.Second)
	s.evidence.ValidUntil = &short
	s.mu.Unlock()
	if err := s.heartbeatOnce(ctx, instance, "exact-deployment", now); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT completeness,dependency_state->>'projection_pool' FROM operations_service_state WHERE service='gateway' AND environment='dev' AND instance_id=$1`, instance).Scan(&complete, &version); err != nil || complete != "unknown" || version != "stale" {
		t.Fatal("ingestion evidence expiry extended", err, complete, version)
	}
	if gatewayHeartbeatInterval != 5*time.Second {
		t.Fatal("source heartbeat cadence changed")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := s.heartbeatOnce(cancelled, instance, "should-not-publish", now); err == nil {
		t.Fatal("failed DB probe published replacement")
	}
}
func TestGatewayTelemetryHeartbeatRejectsInvalidAndTracksRecovery(t *testing.T) {
	at := time.Now()
	drop := at.Add(-2 * time.Second)
	recovered := at.Add(-time.Second)
	for _, fixture := range []struct {
		snapshot       telemetrycore.TelemetrySnapshot
		exporter, loss string
		invalid, lost  bool
	}{
		{telemetrycore.TelemetrySnapshot{Capacity: 2}, "idle_no_export_yet", "none", false, false},
		{telemetrycore.TelemetrySnapshot{Capacity: 2, Dropped: 1, LastDrop: &drop}, "degraded", "unrecovered", false, true},
		{telemetrycore.TelemetrySnapshot{Capacity: 2, Dropped: 1, LastDrop: &drop, LastRecovered: &recovered, LastSuccess: &recovered}, "idle", "recovered", false, false},
		{telemetrycore.TelemetrySnapshot{Capacity: 2, QueueDepth: 3}, "unknown_invalid_snapshot", "", true, false},
	} {
		deps, invalid, _, lost := gatewayTelemetryEvidence(fixture.snapshot, at)
		if deps["telemetry_exporter"] != fixture.exporter || deps["telemetry_loss_state"] != fixture.loss || invalid != fixture.invalid || lost != fixture.lost {
			t.Fatal(deps, invalid, lost)
		}
	}
}
