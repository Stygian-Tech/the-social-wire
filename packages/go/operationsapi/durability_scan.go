package operationsapi

import (
	"bytes"
	"encoding/json"
	"math"
	"strconv"
	"time"
)

const durabilitycheckpointColumns = `environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,last_staged_event_at,last_staged_at,last_applied_seq,last_applied_event_at,last_applied_at,last_reconciled_repo_rev,last_reconciled_at,replay_state,replay_after_seq,replay_before_seq,replay_sealed_seq,replay_bytes_downloaded,replay_retry_count,replay_range_resume_count,replay_last_progress_at,intake_heartbeat_at,updated_at`

func scanDurabilityCheckpoint(row interface{ Scan(...any) error }) (DurabilityCheckpoint, error) {
	value := DurabilityCheckpoint{}
	var lastStagedEventAt *time.Time
	var lastStagedAt *time.Time
	var lastAppliedEventAt *time.Time
	var lastAppliedAt *time.Time
	var lastReconciledAt *time.Time
	var replayLastProgressAt *time.Time
	var intakeHeartbeatAt *time.Time
	var updatedAt time.Time
	err := row.Scan(&value.Environment, &value.SourceGeneration, &value.SourceHost, &value.StreamNSID, &value.FilterFingerprint, &value.CursorKind, &value.LastStagedSequence, &lastStagedEventAt, &lastStagedAt, &value.LastAppliedSequence, &lastAppliedEventAt, &lastAppliedAt, &value.LastReconciledRepositoryRevision, &lastReconciledAt, &value.ReplayState, &value.ReplayAfterSequence, &value.ReplayBeforeSequence, &value.ReplaySealedSequence, &value.ReplayBytesDownloaded, &value.ReplayRetryCount, &value.ReplayRangeResumeCount, &replayLastProgressAt, &intakeHeartbeatAt, &updatedAt)
	if err != nil {
		return value, err
	}
	if lastStagedEventAt != nil {
		value.LastStagedEventAt = &WireTime{*lastStagedEventAt}
	}
	if lastStagedAt != nil {
		value.LastStagedAt = &WireTime{*lastStagedAt}
	}
	if lastAppliedEventAt != nil {
		value.LastAppliedEventAt = &WireTime{*lastAppliedEventAt}
	}
	if lastAppliedAt != nil {
		value.LastAppliedAt = &WireTime{*lastAppliedAt}
	}
	if lastReconciledAt != nil {
		value.LastReconciledAt = &WireTime{*lastReconciledAt}
	}
	if replayLastProgressAt != nil {
		value.ReplayLastProgressAt = &WireTime{*replayLastProgressAt}
	}
	if intakeHeartbeatAt != nil {
		value.IntakeHeartbeatAt = &WireTime{*intakeHeartbeatAt}
	}
	value.UpdatedAt = WireTime{updatedAt}
	switch value.CursorKind {
	case "jetstream_v1_time_us", "jetstream_v2_seq", "unknown":
	default:
		value.CursorKind = "unknown"
	}
	if !knownReplayState(value.ReplayState) {
		value.ReplayState = "failed"
	}
	value.ReplayBytesDownloaded = max(0, value.ReplayBytesDownloaded)
	value.ReplayRetryCount = max(0, value.ReplayRetryCount)
	value.ReplayRangeResumeCount = max(0, value.ReplayRangeResumeCount)
	return value, nil
}

const ingestionincidentColumns = `id,environment,source_generation,source_host,source,cursor_kind,start_cursor,end_cursor,category,status,occurrence_count,first_detected_at,last_detected_at,last_error,replay_state,replay_bytes_downloaded,replay_retry_count,replay_range_resume_count,replay_sealed_seq,recovered_through_cursor,verification_evidence::text,resolved_at,updated_at,version`

func scanIngestionIncident(row interface{ Scan(...any) error }) (IngestionIncident, error) {
	value := IngestionIncident{}
	var firstDetectedAt time.Time
	var lastDetectedAt time.Time
	var evidence string
	var resolvedAt *time.Time
	var updatedAt time.Time
	err := row.Scan(&value.ID, &value.Environment, &value.SourceGeneration, &value.SourceHost, &value.Source, &value.CursorKind, &value.StartCursor, &value.EndCursor, &value.Category, &value.Status, &value.OccurrenceCount, &firstDetectedAt, &lastDetectedAt, &value.LastError, &value.ReplayState, &value.ReplayBytesDownloaded, &value.ReplayRetryCount, &value.ReplayRangeResumeCount, &value.ReplaySealedSequence, &value.RecoveredThroughCursor, &evidence, &resolvedAt, &updatedAt, &value.Version)
	if err != nil {
		return value, err
	}
	value.FirstDetectedAt = WireTime{firstDetectedAt}
	value.LastDetectedAt = WireTime{lastDetectedAt}
	if resolvedAt != nil {
		value.ResolvedAt = &WireTime{*resolvedAt}
	}
	value.UpdatedAt = WireTime{updatedAt}
	switch value.CursorKind {
	case "jetstream_v1_time_us", "jetstream_v2_seq", "unknown":
	default:
		value.CursorKind = "unknown"
	}
	if json.Unmarshal([]byte(evidence), &value.VerificationEvidence) != nil || value.VerificationEvidence == nil {
		value.VerificationEvidence = map[string]json.RawMessage{}
	}
	for _, raw := range value.VerificationEvidence {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		var scalar any
		if decoder.Decode(&scalar) != nil {
			value.VerificationEvidence = map[string]json.RawMessage{}
			break
		}
		switch v := scalar.(type) {
		case nil, string, bool:
		case json.Number:
			n, err := strconv.ParseFloat(string(v), 64)
			if err != nil || math.IsNaN(n) || math.IsInf(n, 0) {
				value.VerificationEvidence = map[string]json.RawMessage{}
			}
		default:
			value.VerificationEvidence = map[string]json.RawMessage{}
		}
	}
	switch value.Status {
	case "open", "recovering", "verification_required", "resolved", "ignored":
	default:
		value.Status = "open"
	}
	if value.ReplayState != nil && !knownReplayState(*value.ReplayState) {
		value.ReplayState = nil
	}
	return value, nil
}
func knownReplayState(value string) bool {
	switch value {
	case "idle", "replaying", "live", "paused_budget", "failed", "snapshot_complete":
		return true
	}
	return false
}
