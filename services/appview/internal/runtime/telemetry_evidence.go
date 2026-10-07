package runtime

import (
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"strconv"
	"time"
)

type heartbeatEvidence struct {
	Dependencies            map[string]string
	Freshness, Completeness string
}

func applyTelemetryEvidence(e *heartbeatEvidence, s telemetrycore.TelemetrySnapshot, at time.Time) {
	d := e.Dependencies
	stamp := func(value *time.Time, fallback string) string {
		if value == nil {
			return fallback
		}
		return value.UTC().Format(time.RFC3339)
	}
	for key, value := range map[string]int{"telemetry_queue_depth": s.QueueDepth, "telemetry_in_flight": s.InFlight, "telemetry_queue_capacity": s.Capacity, "telemetry_dropped_total": s.Dropped, "telemetry_consecutive_failures": s.ConsecutiveFailures} {
		d[key] = strconv.Itoa(value)
	}
	d["telemetry_last_successful_export_at"] = stamp(s.LastSuccess, "none")
	d["telemetry_last_drop_at"] = stamp(s.LastDrop, "unknown")
	d["telemetry_last_drop_recovered_at"] = stamp(s.LastRecovered, "none")
	d["telemetry_snapshot_observed_at"] = at.UTC().Format(time.RFC3339)
	d["telemetry_last_export_age_seconds"] = "unknown"
	valid := s.QueueDepth >= 0 && s.InFlight >= 0 && s.Capacity > 0 && s.Dropped >= 0 && s.ConsecutiveFailures >= 0 && s.QueueDepth <= s.Capacity-s.InFlight && (s.Dropped > 0 || s.LastDrop == nil)
	for _, value := range []*time.Time{s.LastSuccess, s.LastDrop, s.LastRecovered} {
		valid = valid && (value == nil || !value.After(at))
	}
	if s.LastSuccess != nil {
		age := at.Sub(*s.LastSuccess).Seconds()
		if age < 0 {
			d["telemetry_last_export_age_seconds"] = "invalid_future"
		} else {
			d["telemetry_last_export_age_seconds"] = fmt.Sprintf("%.3f", age)
		}
	}
	if s.LastRecovered != nil {
		valid = valid && s.Dropped > 0 && s.LastDrop != nil && s.LastRecovered.After(*s.LastDrop) && s.LastSuccess != nil && !s.LastRecovered.After(*s.LastSuccess)
	}
	if !valid {
		d["telemetry_exporter"] = "unknown_invalid_snapshot"
		if e.Freshness == "healthy" {
			e.Freshness = "unknown"
		}
		if e.Completeness == "healthy" {
			e.Completeness = "unknown"
		}
		return
	}
	drop := s.Dropped > 0 && s.LastRecovered == nil
	d["telemetry_loss_state"] = "none"
	if s.Dropped > 0 {
		d["telemetry_loss_state"] = "recovered"
		if drop {
			d["telemetry_loss_state"] = "unrecovered"
		}
	}
	state := "idle"
	if s.ConsecutiveFailures > 0 || drop {
		state = "degraded"
	} else if s.InFlight > 0 {
		state = "exporting"
	} else if s.QueueDepth > 0 {
		state = "queued"
	} else if s.LastSuccess == nil {
		state = "idle_no_export_yet"
	}
	d["telemetry_exporter"] = state
	if s.ConsecutiveFailures > 0 && e.Freshness == "healthy" {
		e.Freshness = "degraded"
	}
	if drop && e.Completeness == "healthy" {
		e.Completeness = "degraded"
	}
}
