package appviewworkercore

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestTelemetryCapacityIncludesInFlightAndLossRecoveryLatches(t *testing.T) {
	var clock atomic.Int64
	clock.Store(time.Now().UnixNano())
	entered, release := make(chan struct{}), make(chan struct{})
	buffer := TelemetryBuffer{Capacity: 2, BatchSize: 2, Now: func() time.Time { return time.Unix(0, clock.Add(1)) }, Export: func(context.Context, []MetricSample) error { close(entered); <-release; return nil }}
	for i := 0; i < 2; i++ {
		if !buffer.Enqueue(MetricSample{Name: "fixture", Value: 1}) {
			t.Fatal("queue full early")
		}
	}
	done := make(chan error, 1)
	go func() { _, err := buffer.Flush(context.Background()); done <- err }()
	<-entered
	if buffer.Enqueue(MetricSample{Name: "overflow"}) {
		t.Fatal("in-flight reservation omitted")
	}
	s := buffer.Snapshot()
	if s.InFlight != 2 || s.QueueDepth != 0 || s.Dropped != 1 {
		t.Fatal(s)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	s = buffer.Snapshot()
	if s.LastRecovered == nil || s.LastSuccess == nil || s.Dropped != 1 || s.InFlight != 0 {
		t.Fatal(s)
	}
	e := ingestionEvidence{Freshness: "healthy", Completeness: "healthy", Dependencies: map[string]string{}}
	applyTelemetryEvidence(&e, s, time.Unix(0, clock.Add(1)))
	if e.Dependencies["telemetry_loss_state"] != "recovered" || e.Completeness != "healthy" {
		t.Fatal(e)
	}
}
func TestTelemetryAmbiguousFailureNeverReplaysAdditiveBatch(t *testing.T) {
	calls := 0
	buffer := TelemetryBuffer{Export: func(context.Context, []MetricSample) error { calls++; return errors.New("lost commit reply") }}
	buffer.Enqueue(MetricSample{Name: "fixture", Value: 1})
	if _, err := buffer.Flush(context.Background()); err == nil {
		t.Fatal("ambiguous export accepted")
	}
	s := buffer.Snapshot()
	if calls != 1 || s.Dropped != 1 || s.QueueDepth != 0 || s.ConsecutiveFailures != 1 {
		t.Fatal(s)
	}
	e := ingestionEvidence{Freshness: "healthy", Completeness: "healthy", Dependencies: map[string]string{}}
	applyTelemetryEvidence(&e, s, time.Now())
	if e.Freshness != "degraded" || e.Completeness != "degraded" || e.Dependencies["telemetry_loss_state"] != "unrecovered" {
		t.Fatal(e)
	}
}
func TestTelemetryRolledBackContentionDefersWithoutLossOrReordering(t *testing.T) {
	at := time.Now()
	calls := 0
	buffer := TelemetryBuffer{MaximumAttempts: 1, Now: func() time.Time { return at }, Export: func(_ context.Context, batch []MetricSample) error {
		calls++
		if calls == 1 {
			return &telemetryExportError{errors.New("rolled back lock timeout"), true}
		}
		if len(batch) != 2 || batch[0].Name != "first" || batch[1].Name != "second" {
			t.Fatal(batch)
		}
		return nil
	}}
	buffer.Enqueue(MetricSample{Name: "first", Value: 1})
	buffer.Enqueue(MetricSample{Name: "second", Value: 1})
	if _, err := buffer.Flush(context.Background()); err == nil {
		t.Fatal("contention missing")
	}
	s := buffer.Snapshot()
	if s.QueueDepth != 2 || s.Dropped != 0 || s.InFlight != 0 {
		t.Fatal(s)
	}
	if n, err := buffer.Flush(context.Background()); n != 0 || err != nil {
		t.Fatal("retry did not yield")
	}
	at = at.Add(6 * time.Second)
	if n, err := buffer.Flush(context.Background()); n != 2 || err != nil {
		t.Fatalf("deferred export %d %v", n, err)
	}
}
