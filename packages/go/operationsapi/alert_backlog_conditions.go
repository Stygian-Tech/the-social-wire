package operationsapi

import (
	"fmt"
	"math"
	"time"
)

func legacyBacklogConditions(state *StreamState, isAuthority bool, config Config, at time.Time) []AlertCondition {
	severity, role := "warning", "supplemental_unverified"
	if isAuthority {
		severity = "critical"
		role = "authority"
	}
	evidence := map[string]string{"cursor_delta_microseconds": "unknown", "role": role, "transport_heartbeat_at": "none", "queue_observed_at": "none", "queue_depth": "unknown", "queue_capacity": "unknown", "observedAt": "none", "validUntil": "none"}
	var transport, transportUntil, queueAt, queueUntil *time.Time
	var queue *EvidenceMetadata
	var delta *int64
	if state != nil {
		if state.LastReceivedCursor != nil && state.LastCommittedCursor != nil {
			received, committed := *state.LastReceivedCursor, *state.LastCommittedCursor
			n := int64(0)
			if received > committed {
				diff := uint64(received) - uint64(committed)
				if diff > math.MaxInt64 {
					n = math.MaxInt64
				} else {
					n = int64(diff)
				}
			}
			delta = &n
			evidence["cursor_delta_microseconds"] = fmt.Sprint(n)
		}
		if state.TransportHeartbeatAt != nil {
			transport = pointer(state.TransportHeartbeatAt.Time)
			transportUntil = pointer(transport.Add(config.IdleAlert))
			evidence["transport_heartbeat_at"] = transport.UTC().Format(time.RFC3339)
		}
		queue = state.QueueEvidence
		evidence["queue_depth"] = fmt.Sprint(state.QueueDepth)
		if state.QueueCapacity != nil {
			evidence["queue_capacity"] = fmt.Sprint(*state.QueueCapacity)
		}
	}
	if queue != nil {
		queueUntil = pointer(queue.ValidUntil.Time)
		if queue.IndexedThrough != nil {
			queueAt = pointer(queue.IndexedThrough.Time)
			evidence["queue_observed_at"] = queueAt.UTC().Format(time.RFC3339)
		}
	}
	for _, v := range []*time.Time{transport, queueAt} {
		if v != nil && (evidence["observedAt"] == "none" || v.UTC().Format(time.RFC3339) < evidence["observedAt"]) {
			evidence["observedAt"] = v.UTC().Format(time.RFC3339)
		}
	}
	for _, v := range []*time.Time{transportUntil, queueUntil} {
		if v != nil && (evidence["validUntil"] == "none" || v.UTC().Format(time.RFC3339) < evidence["validUntil"]) {
			evidence["validUntil"] = v.UTC().Format(time.RFC3339)
		}
	}
	missing := queue == nil || queue.Accuracy != "exact" || queueAt == nil
	expired := !missing && !at.Before(queue.ValidUntil.Time)
	current := transport != nil && at.Before(*transportUntil)
	return []AlertCondition{
		{missing, "jetstream_queue_evidence_missing", "jetstream:queue_evidence_missing", severity, "No exact Jetstream processing-queue observation is available.", "live-process-stalled-ingestion", evidence},
		{expired, "jetstream_queue_evidence_expired", "jetstream:queue_evidence_expired", severity, "The Jetstream processing-queue observation has expired.", "live-process-stalled-ingestion", evidence},
		{current && !missing && !expired && delta != nil && *delta >= config.BacklogAlertMicroseconds, "jetstream_commit_backlog", "jetstream:commit_backlog", severity, "The measured Jetstream receive-to-commit backlog is above threshold.", "live-process-stalled-ingestion", evidence},
	}
}
