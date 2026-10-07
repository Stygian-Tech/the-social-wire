package operationsapi

import (
	"context"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
)

type Runtime struct {
	Store     *PostgresStore
	Config    Config
	Telemetry *telemetrycore.TelemetryBuffer
	Webhook   *WebhookDelivery
	Version   *string
	startedAt time.Time
}

// Background schedules are independent and never overlap their own work. A
// failed observation retains the previous evidence and lets it expire naturally.
func (r *Runtime) Run(ctx context.Context) error {
	r.startedAt = time.Now()
	evidence := &EvidenceMonitor{Store: r.Store}
	capabilities := &EvidenceMonitor{Store: r.Store}
	var wg sync.WaitGroup
	start := func(run func()) { wg.Add(1); go func() { defer wg.Done(); run() }() }
	schedule := func(interval time.Duration, label string, operation func(context.Context, time.Time) error, subtractElapsed bool) {
		start(func() {
			for ctx.Err() == nil {
				at := time.Now()
				if e := operation(ctx, at); e != nil && ctx.Err() == nil {
					slog.Warn(label, "error_category", ErrorCategory(e))
				}
				delay := interval
				if subtractElapsed {
					elapsed := time.Since(at)
					if elapsed < interval {
						delay = interval - elapsed
					}
				}
				if !sleepContext(ctx, delay) {
					return
				}
			}
		})
	}
	if r.Config.Enabled && r.Telemetry != nil {
		start(func() { _ = r.Telemetry.Run(ctx) })
	}
	schedule(5*time.Second, "Operations heartbeat unavailable", r.Heartbeat, false)
	evaluator := AlertEvaluator{Store: r.Store, Config: r.Config, Webhook: r.Webhook}
	schedule(30*time.Second, "Operations alert evaluation unavailable", evaluator.Evaluate, false)
	schedule(5*time.Second, "Operations capability event unavailable", func(ctx context.Context, at time.Time) error {
		return capabilities.ObserveCapabilities(ctx, r.Config, at)
	}, false)
	schedule(1500*time.Millisecond, "Operations evidence event unavailable", evidence.Observe, false)
	schedule(time.Hour, "Operations viewer history unavailable", r.Store.RecordViewerHistory, false)
	for group, interval := range databaseCostIntervals {
		schedule(interval, "Operations database cost observation unavailable", func(ctx context.Context, at time.Time) error {
			return r.Store.RecordDatabaseCostTelemetry(ctx, group, at)
		}, true)
	}
	start(func() { r.retention(ctx) })
	<-ctx.Done()
	wg.Wait()
	// A canceled in-flight export is not retried automatically. Flush only the
	// surviving buffered items within a new bounded shutdown budget.
	if r.Config.Enabled && r.Telemetry != nil {
		flush, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, _ = r.Telemetry.Flush(flush)
		cancel()
	}
	return ctx.Err()
}
func (r *Runtime) emit(name string, value float64, at time.Time) {
	if r.Config.Enabled && r.Telemetry != nil {
		r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: name, Value: value, Dimensions: map[string]string{"service": "operations"}, At: at})
	}
}
func (r *Runtime) retention(ctx context.Context) {
	failures := 0
	for ctx.Err() == nil {
		start := time.Now()
		round, e := RunRetentionRound(ctx, r.Store.CleanupExpired, time.Now)
		delay := time.Hour
		if e == nil {
			failures = 0
			if r.Config.RetentionCatchUpEnabled && !round.Drained {
				delay = time.Second
			}
			at := time.Now()
			backlog := 0.0
			if !round.Drained {
				backlog = 1
			}
			for name, value := range map[string]float64{"deleted_rows": float64(round.Deleted), "calls": float64(round.Calls), "duration_ms": float64(time.Since(start)) / float64(time.Millisecond), "last_success_timestamp": float64(at.UnixNano()) / 1e9, "backlog_pending": backlog} {
				r.emit("operations.retention."+name, value, at)
			}
		} else {
			if ctx.Err() != nil {
				return
			}
			failures++
			r.emit("operations.retention.failures", 1, time.Now())
			if r.Config.RetentionCatchUpEnabled {
				delay = RetentionFailureDelay(failures)
			}
			slog.Warn("Operations retention cleanup unavailable", "error_category", ErrorCategory(e))
		}
		if !sleepContext(ctx, delay) {
			return
		}
	}
}
func (r *Runtime) Heartbeat(ctx context.Context, at time.Time) error {
	if e := r.Store.Ping(ctx); e != nil {
		return e
	}
	state := ServiceState{Service: "operations", Environment: r.Config.Environment, InstanceID: r.Config.InstanceID, Version: r.Version, StartedAt: r.startedAt, HeartbeatAt: at, Liveness: "healthy", Readiness: "healthy", Freshness: "unknown", Completeness: "unknown", DependencyState: map[string]string{"operations_database": "ready"}}
	bounds, e := r.Store.ChangeEventCursorBounds(ctx)
	if e != nil {
		state.Liveness = "degraded"
		state.Readiness = "degraded"
		state.DependencyState["service_probe"] = "failed:" + ErrorCategory(e)
	} else {
		dependencies := state.DependencyState
		dependencies["operations_store"] = "ready"
		dependencies["event_log"] = "ready"
		dependencies["event_log_earliest_cursor"] = strconv.FormatInt(bounds.EarliestAvailable, 10)
		dependencies["event_log_latest_cursor"] = strconv.FormatInt(bounds.Latest, 10)
		delivery := "disabled_by_configuration"
		if r.Config.AlertDeliveryEnabled {
			delivery = "ready"
			if r.Config.WebhookURL == "" || r.Config.WebhookSecret == "" {
				delivery = "misconfigured"
				state.Readiness = "degraded"
			}
		}
		dependencies["alert_delivery"] = delivery
		if r.Config.Enabled && r.Telemetry != nil {
			snapshot := r.Telemetry.Snapshot()
			state.Freshness = "healthy"
			state.Completeness = "healthy"
			if snapshot.ConsecutiveFailures > 0 {
				state.Readiness = "degraded"
				state.Freshness = "degraded"
			}
			if snapshot.Dropped > 0 {
				state.Completeness = "degraded"
			}
			for key, value := range telemetryHeartbeatEvidence(snapshot, at) {
				dependencies[key] = value
			}
		} else {
			dependencies["telemetry_exporter"] = "disabled_by_configuration"
		}
	}
	if e = r.Store.UpsertServiceState(ctx, state); e != nil {
		return e
	}
	for dimension, health := range map[string]string{"liveness": state.Liveness, "readiness": state.Readiness, "freshness": state.Freshness, "completeness": state.Completeness} {
		if r.Config.Enabled && r.Telemetry != nil {
			r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.service.health.samples_total", Value: 1, Dimensions: map[string]string{"service": "operations", "dimension": dimension, "state": health}, At: at})
		}
	}
	return nil
}
func telemetryHeartbeatEvidence(s telemetrycore.TelemetrySnapshot, at time.Time) map[string]string {
	stamp := func(t *time.Time, fallback string) string {
		if t == nil {
			return fallback
		}
		return t.UTC().Format(time.RFC3339)
	}
	loss := "none"
	if s.Dropped > 0 {
		loss = "unrecovered"
		if s.LastRecovered != nil {
			loss = "recovered"
		}
	}
	exporter := "idle"
	switch {
	case s.ConsecutiveFailures > 0 || loss == "unrecovered":
		exporter = "degraded"
	case s.InFlight > 0:
		exporter = "exporting"
	case s.QueueDepth > 0:
		exporter = "queued"
	case s.LastSuccess == nil:
		exporter = "idle_no_export_yet"
	}
	age := "unknown"
	if s.LastSuccess != nil {
		age = strconv.FormatFloat(max(0, at.Sub(*s.LastSuccess).Seconds()), 'f', 3, 64)
	}
	return map[string]string{"telemetry_queue_depth": strconv.Itoa(s.QueueDepth), "telemetry_in_flight": strconv.Itoa(s.InFlight), "telemetry_queue_capacity": strconv.Itoa(s.Capacity), "telemetry_dropped_total": strconv.Itoa(s.Dropped), "telemetry_consecutive_failures": strconv.Itoa(s.ConsecutiveFailures), "telemetry_last_successful_export_at": stamp(s.LastSuccess, "none"), "telemetry_last_drop_at": stamp(s.LastDrop, "unknown"), "telemetry_last_drop_recovered_at": stamp(s.LastRecovered, "none"), "telemetry_snapshot_observed_at": at.UTC().Format(time.RFC3339), "telemetry_last_export_age_seconds": age, "telemetry_loss_state": loss, "telemetry_exporter": exporter}
}
