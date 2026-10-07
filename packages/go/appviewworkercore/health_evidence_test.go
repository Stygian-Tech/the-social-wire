package appviewworkercore

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"
)

func workerDatabase(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("explicit disposable canonical database required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
func TestHeartbeatReadinessRejectsUnknownStaleAndUnhealthyEvidence(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	h := Host{DB: db, Config: HostConfig{Environment: "dev", InstanceID: nonce, Role: "projection", Generation: "go-health-" + nonce}}
	ctx := context.Background()
	t.Cleanup(func() {
		db.Exec("DELETE FROM operations_service_state WHERE environment=$1 AND instance_id=$2", h.Config.Environment, h.Config.InstanceID)
	})
	if err := h.checkReadiness(ctx); err == nil {
		t.Fatal("missing heartbeat accepted")
	}
	now := time.Now()
	unknown, err := h.evidence(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if unknown.Liveness != "unknown" || unknown.Completeness != "unknown" {
		t.Fatalf("missing intake made healthy %+v", unknown)
	}
	if err := h.publishHeartbeat(ctx, unknown, nil, now, now); err != nil {
		t.Fatal(err)
	}
	if err := h.checkReadiness(ctx); err == nil {
		t.Fatal("unknown intake accepted")
	}
	healthy := ingestionEvidence{Liveness: "healthy", Freshness: "healthy", Completeness: "healthy", Dependencies: map[string]string{}}
	if err := h.publishHeartbeat(ctx, healthy, nil, now, now); err != nil {
		t.Fatal(err)
	}
	if err := h.checkReadiness(ctx); err != nil {
		t.Fatal(err)
	}
	if err := h.publishHeartbeat(ctx, healthy, nil, now, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := h.checkReadiness(ctx); err == nil {
		t.Fatal("stale heartbeat accepted")
	}
	healthy.Completeness = "unhealthy"
	if err := h.publishHeartbeat(ctx, healthy, nil, now, now); err != nil {
		t.Fatal(err)
	}
	if err := h.checkReadiness(ctx); err == nil {
		t.Fatal("dead-letter completeness accepted")
	}
}

func TestHeartbeatEnqueuesCanonicalHealthSamplesAfterPersistence(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	h := Host{DB: db, Config: HostConfig{Environment: "dev", Role: "projection", InstanceID: nonce}}
	t.Cleanup(func() {
		db.Exec("DELETE FROM operations_service_state WHERE environment='dev'AND instance_id=$1", nonce)
	})
	samples := []MetricSample{}
	h.Telemetry = &TelemetryBuffer{Export: func(_ context.Context, batch []MetricSample) error { samples = append(samples, batch...); return nil }}
	at := time.Now()
	e := ingestionEvidence{Liveness: "healthy", Freshness: "unknown", Completeness: "degraded", Dependencies: map[string]string{}}
	for i := 0; i < 2; i++ {
		if err := h.publishHeartbeat(context.Background(), e, nil, at, at); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.Telemetry.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(samples) != 8 {
		t.Fatal(len(samples))
	}
	counts := map[string]int{}
	for _, sample := range samples {
		if sample.Name != "socialwire.service.health.samples_total" || sample.Value != 1 || sample.Dimensions["service"] != "projection-pool-appview" {
			t.Fatal(sample)
		}
		counts[sample.Dimensions["dimension"]]++
	}
	for _, dimension := range []string{"liveness", "readiness", "freshness", "completeness"} {
		if counts[dimension] != 2 {
			t.Fatal(counts)
		}
	}
}
