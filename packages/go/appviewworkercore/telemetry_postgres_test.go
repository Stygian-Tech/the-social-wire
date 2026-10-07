package appviewworkercore

import (
	"context"
	"testing"
	"time"
)

func TestTelemetryExporterPreservesWeightedRollupsAndRedactsDimensions(t *testing.T) {
	db := workerDatabase(t)
	nonce, err := newSnapshotToken()
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC().Truncate(time.Minute)
	h := Host{DB: db, Config: HostConfig{Environment: "dev"}}
	dimensions := map[string]string{"service": nonce, "collection": "site.standard.document", "authorization": "private"}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM operations_metric_rollups WHERE environment='dev'AND dimensions->>'service'=$1`, nonce)
	})
	samples := []MetricSample{{Name: "socialwire.ingestion.events_total", Value: 1, Dimensions: dimensions, At: at}, {Name: "socialwire.ingestion.events_total", Value: 2, Dimensions: dimensions, At: at}}
	for i := 0; i < 2; i++ {
		if err := h.exportTelemetry(context.Background(), samples); err != nil {
			t.Fatal(err)
		}
	}
	var count int
	var sum, minimum, maximum float64
	var secret bool
	var expires time.Time
	if err := db.QueryRow(`SELECT sample_count,value_sum,value_min,value_max,dimensions?'authorization',expires_at FROM operations_metric_rollups WHERE environment='dev'AND metric_name='socialwire.ingestion.events_total'AND dimensions->>'service'=$1`, nonce).Scan(&count, &sum, &minimum, &maximum, &secret, &expires); err != nil {
		t.Fatal(err)
	}
	if count != 4 || sum != 6 || minimum != 1 || maximum != 2 || secret || expires.Sub(at) != 90*24*time.Hour {
		t.Fatalf("rollup %d %f %f %f %v %s", count, sum, minimum, maximum, secret, expires)
	}
	dimensions["environment"] = "prod"
	if err := h.exportTelemetry(context.Background(), samples); err == nil {
		t.Fatal("cross environment telemetry accepted")
	}
}
