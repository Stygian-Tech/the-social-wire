package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"time"
)

const streamColumns = `environment,source,connection_state,connected_at,last_disconnect_at,last_disconnect_reason,last_received_cursor,last_received_event_at,last_received_at,last_committed_cursor,last_committed_event_at,last_committed_at,queue_depth,queue_capacity,queue_overflow_total,transport_heartbeat_at,last_indexed_mutation_at,projection_watermark,validation_watermark,heartbeat_at,version,queue_observed_at`

func scanStream(row interface{ Scan(...any) error }, at time.Time) (StreamState, error) {
	state := StreamState{}
	var queueObserved *time.Time
	var connectedAt *time.Time
	var lastDisconnectAt *time.Time
	var lastReceivedEventAt *time.Time
	var lastReceivedAt *time.Time
	var lastCommittedEventAt *time.Time
	var lastCommittedAt *time.Time
	var transportHeartbeatAt *time.Time
	var lastIndexedMutationAt *time.Time
	var heartbeatAt time.Time
	err := row.Scan(&state.Environment, &state.Source, &state.ConnectionState, &connectedAt, &lastDisconnectAt, &state.LastDisconnectReason, &state.LastReceivedCursor, &lastReceivedEventAt, &lastReceivedAt, &state.LastCommittedCursor, &lastCommittedEventAt, &lastCommittedAt, &state.QueueDepth, &state.QueueCapacity, &state.QueueOverflowTotal, &transportHeartbeatAt, &lastIndexedMutationAt, &state.ProjectionWatermark, &state.ValidationWatermark, &heartbeatAt, &state.Version, &queueObserved)
	if err != nil {
		return state, err
	}
	if connectedAt != nil {
		state.ConnectedAt = &WireTime{*connectedAt}
	}
	if lastDisconnectAt != nil {
		state.LastDisconnectAt = &WireTime{*lastDisconnectAt}
	}
	if lastReceivedEventAt != nil {
		state.LastReceivedEventAt = &WireTime{*lastReceivedEventAt}
	}
	if lastReceivedAt != nil {
		state.LastReceivedAt = &WireTime{*lastReceivedAt}
	}
	if lastCommittedEventAt != nil {
		state.LastCommittedEventAt = &WireTime{*lastCommittedEventAt}
	}
	if lastCommittedAt != nil {
		state.LastCommittedAt = &WireTime{*lastCommittedAt}
	}
	if transportHeartbeatAt != nil {
		state.TransportHeartbeatAt = &WireTime{*transportHeartbeatAt}
	}
	if lastIndexedMutationAt != nil {
		state.LastIndexedMutationAt = &WireTime{*lastIndexedMutationAt}
	}
	state.HeartbeatAt = WireTime{heartbeatAt}
	switch state.ConnectionState {
	case "connected", "disconnected", "reconnecting", "unknown":
	default:
		state.ConnectionState = "unknown"
	}
	if queueObserved != nil {
		coverage := 1.0
		observed := WireTime{*queueObserved}
		state.QueueEvidence = &EvidenceMetadata{Source: state.Source + "_transport_queue", Accuracy: "exact", GeneratedAt: observed, IndexedThrough: &observed, AgeSeconds: max(0, at.Sub(*queueObserved).Seconds()), ValidUntil: WireTime{queueObserved.Add(15 * time.Second)}, Coverage: &coverage, LastSuccessfulAt: &observed}
	}
	return state, nil
}
func (s *PostgresStore) FetchStreamState(ctx context.Context, source string) (*StreamState, error) {
	state, err := scanStream(s.DB.QueryRow(ctx, `SELECT `+streamColumns+` FROM appview_ingestion_stream_state WHERE environment=$1 AND source=$2 LIMIT 1`, s.Environment, source), time.Now())
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &state, nil
}
func (s *PostgresStore) ListStreamStates(ctx context.Context) ([]StreamState, error) {
	rows, err := s.DB.Query(ctx, `SELECT `+streamColumns+` FROM appview_ingestion_stream_state WHERE environment=$1 ORDER BY source`, s.Environment)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	states := []StreamState{}
	for rows.Next() {
		state, err := scanStream(rows, time.Now())
		if err != nil {
			return nil, err
		}
		states = append(states, state)
	}
	return states, rows.Err()
}
func (s *PostgresStore) UpsertServiceState(ctx context.Context, state ServiceState) error {
	if state.Environment != s.Environment {
		return ErrEnvironmentMismatch
	}
	if state.Service == "coordinator-appview" {
		return ErrLeaseConflict
	}
	dependencies, err := json.Marshal(state.DependencyState)
	if err != nil {
		return err
	}
	if state.DependencyState == nil {
		dependencies = []byte(`{}`)
	}
	_, err = s.DB.Exec(ctx, `INSERT INTO operations_service_state(service,environment,instance_id,liveness,readiness,freshness,completeness,dependency_state,version,started_at,heartbeat_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10,$11) ON CONFLICT(service,environment,instance_id) DO UPDATE SET liveness=EXCLUDED.liveness,readiness=EXCLUDED.readiness,freshness=EXCLUDED.freshness,completeness=EXCLUDED.completeness,dependency_state=EXCLUDED.dependency_state,version=EXCLUDED.version,heartbeat_at=EXCLUDED.heartbeat_at`, state.Service, state.Environment, state.InstanceID, state.Liveness, state.Readiness, state.Freshness, state.Completeness, string(dependencies), state.Version, state.StartedAt, state.HeartbeatAt)
	return err
}
func (s *PostgresStore) LifecycleCounts(ctx context.Context) (LifecycleCounts, error) {
	counts := LifecycleCounts{}
	err := s.DB.QueryRow(ctx, `SELECT (SELECT count(*) FROM appview_ingestion_gaps WHERE environment=$1 AND status NOT IN ('resolved','ignored')),(SELECT count(*) FROM appview_backfill_jobs WHERE environment=$1 AND status IN ('queued','running','paused')),(SELECT count(*) FROM appview_backfill_jobs WHERE environment=$1 AND status IN ('failed','cancelled')),(SELECT count(*) FROM appview_backfill_jobs WHERE environment=$1 AND status='completed'),(SELECT count(*) FROM operations_alerts WHERE environment=$1 AND status!='resolved')`, s.Environment).Scan(&counts.ActiveGaps, &counts.ActiveBackfills, &counts.AttentionBackfills, &counts.CompletedBackfills, &counts.UnresolvedAlerts)
	return counts, err
}
