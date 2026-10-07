package gateway

import (
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"strconv"
	"time"
)

func gatewayTelemetryEvidence(s telemetrycore.TelemetrySnapshot, at time.Time) (map[string]string, bool, bool, bool) {
	stamp := func(v *time.Time, fallback string) string {
		if v == nil {
			return fallback
		}
		return v.UTC().Format(time.RFC3339)
	}
	deps := map[string]string{"telemetry_queue_depth": strconv.Itoa(s.QueueDepth), "telemetry_in_flight": strconv.Itoa(s.InFlight), "telemetry_queue_capacity": strconv.Itoa(s.Capacity), "telemetry_dropped_total": strconv.Itoa(s.Dropped), "telemetry_consecutive_failures": strconv.Itoa(s.ConsecutiveFailures), "telemetry_last_successful_export_at": stamp(s.LastSuccess, "none"), "telemetry_last_drop_at": stamp(s.LastDrop, "unknown"), "telemetry_last_drop_recovered_at": stamp(s.LastRecovered, "none"), "telemetry_snapshot_observed_at": at.UTC().Format(time.RFC3339), "telemetry_last_export_age_seconds": "unknown"}
	invalid := s.QueueDepth < 0 || s.InFlight < 0 || s.Capacity <= 0 || s.Dropped < 0 || s.ConsecutiveFailures < 0 || s.InFlight > s.Capacity || s.QueueDepth > s.Capacity-s.InFlight || (s.Dropped == 0 && s.LastDrop != nil)
	for _, date := range []*time.Time{s.LastSuccess, s.LastDrop, s.LastRecovered} {
		if date != nil && date.After(at) {
			invalid = true
		}
	}
	if s.LastSuccess != nil {
		if s.LastSuccess.After(at) {
			deps["telemetry_last_export_age_seconds"] = "invalid_future"
		} else {
			deps["telemetry_last_export_age_seconds"] = fmt.Sprintf("%.3f", at.Sub(*s.LastSuccess).Seconds())
		}
	}
	if s.LastRecovered != nil && (s.Dropped == 0 || s.LastDrop == nil || !s.LastRecovered.After(*s.LastDrop) || s.LastSuccess == nil || s.LastRecovered.After(*s.LastSuccess)) {
		invalid = true
	}
	if invalid {
		deps["telemetry_exporter"] = "unknown_invalid_snapshot"
		return deps, true, false, false
	}
	failed, lost := s.ConsecutiveFailures > 0, s.Dropped > 0 && s.LastRecovered == nil
	deps["telemetry_loss_state"] = "none"
	if s.Dropped > 0 {
		deps["telemetry_loss_state"] = "recovered"
		if lost {
			deps["telemetry_loss_state"] = "unrecovered"
		}
	}
	exporter := "idle"
	switch {
	case failed || lost:
		exporter = "degraded"
	case s.InFlight > 0:
		exporter = "exporting"
	case s.QueueDepth > 0:
		exporter = "queued"
	case s.LastSuccess == nil:
		exporter = "idle_no_export_yet"
	}
	deps["telemetry_exporter"] = exporter
	return deps, false, failed, lost
}
