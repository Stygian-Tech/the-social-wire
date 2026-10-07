package telemetrycore

import (
	"context"
	"database/sql"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestTelemetryEventsAreCopiedBeforeExport(t *testing.T) {
	request := "original"
	event := EventSample{ID: "fixture", Environment: "dev", RequestID: &request, Attributes: map[string]string{"count": "1"}}
	buffer := TelemetryBuffer{Export: func(_ context.Context, samples []MetricSample) error {
		if samples[0].Event == nil || *samples[0].Event.RequestID != "original" || samples[0].Event.Attributes["count"] != "1" {
			t.Fatal("mutable event shared", samples)
		}
		return nil
	}}
	buffer.Enqueue(MetricSample{Event: &event})
	request = "changed"
	event.Attributes["count"] = "2"
	if _, err := buffer.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
}
func TestPostgresTelemetryBatchesStableIdentitiesBeforeRollups(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(4)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	fixture := fmt.Sprintf("telemetry-%d", time.Now().UnixNano())
	at := time.Now().UTC().Truncate(time.Minute)
	exporter := PostgresExporter{DB: db, Environment: "dev"}
	t.Cleanup(func() {
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = db.ExecContext(c, `DELETE FROM operations_events WHERE environment='dev' AND instance_id=$1`, fixture)
		_, _ = db.ExecContext(c, `DELETE FROM operations_trace_spans WHERE environment='dev' AND trace_id=$1`, fixture)
		_, _ = db.ExecContext(c, `DELETE FROM operations_metric_rollups WHERE environment='dev' AND metric_name=$1`, fixture)
	})
	samples := []MetricSample{}
	empty := ""
	for i := 0; i < 501; i++ {
		id := fmt.Sprintf("%s-%04d", fixture, i)
		samples = append(samples, MetricSample{Event: &EventSample{ID: id, Environment: "dev", Service: "fixture", InstanceID: fixture, Name: "fixture", OccurredAt: at, RequestID: &empty, Attributes: map[string]string{"secret": "private", "count": "1"}}}, MetricSample{Span: &SpanSample{ID: id, Environment: "dev", TraceID: fixture, ParentSpanIDValue: &empty, Service: "fixture", Name: "fixture", StartedAt: at, ExpiresAt: at.Add(time.Hour), DurationMS: 1, Status: "ok", Attributes: map[string]string{"token": "private", "count": "1"}}}, MetricSample{Name: fixture, Value: float64(i), Dimensions: map[string]string{"fixtureKey": fmt.Sprint(i)}, At: at})
	}
	reversed := slices.Clone(samples)
	slices.Reverse(reversed)
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i, batch := range [][]MetricSample{samples, reversed} {
		wg.Add(1)
		go func() { defer wg.Done(); errs[i] = exporter.Export(ctx, batch) }()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, query := range []string{`SELECT count(*) FROM operations_events WHERE environment='dev' AND instance_id=$1`, `SELECT count(*) FROM operations_trace_spans WHERE environment='dev' AND trace_id=$1`} {
		var count int
		if err = db.QueryRowContext(ctx, query, fixture).Scan(&count); err != nil || count != 501 {
			t.Fatal(count, err)
		}
	}
	var count, weight int
	var sum float64
	if err = db.QueryRowContext(ctx, `SELECT count(*),sum(sample_count),sum(value_sum) FROM operations_metric_rollups WHERE environment='dev' AND metric_name=$1`, fixture).Scan(&count, &weight, &sum); err != nil || count != 501 || weight != 1002 || sum != 250500 {
		t.Fatal(count, weight, sum, err)
	}
	var request, attributes string
	if err = db.QueryRowContext(ctx, `SELECT request_id,attributes::text FROM operations_events WHERE environment='dev' AND id=$1`, fixture+"-0000").Scan(&request, &attributes); err != nil || request != "" || strings.Contains(attributes, "secret") {
		t.Fatal(request, attributes, err)
	}
	var parent string
	if err = db.QueryRowContext(ctx, `SELECT parent_span_id FROM operations_trace_spans WHERE environment='dev' AND id=$1`, fixture+"-0000").Scan(&parent); err != nil || parent != "" {
		t.Fatal("explicit empty optional parent lost", parent, err)
	}
	// Reject a mixed-environment batch before inserting any identity or additive metric.
	invalid := append(slices.Clone(samples), MetricSample{Event: &EventSample{Environment: "prod"}})
	if err = exporter.Export(ctx, invalid); err == nil {
		t.Fatal("mixed environment accepted")
	}
	if err = db.QueryRowContext(ctx, `SELECT sum(sample_count) FROM operations_metric_rollups WHERE environment='dev' AND metric_name=$1`, fixture).Scan(&weight); err != nil || weight != 1002 {
		t.Fatal("invalid batch partially persisted", weight, err)
	}
}
