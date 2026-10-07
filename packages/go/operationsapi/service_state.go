package operationsapi

import (
	"context"
	"encoding/json"
	"time"
)

type ServiceState struct {
	Service         string            `json:"service"`
	Environment     string            `json:"environment"`
	InstanceID      string            `json:"instanceId"`
	Liveness        string            `json:"liveness"`
	Readiness       string            `json:"readiness"`
	Freshness       string            `json:"freshness"`
	Completeness    string            `json:"completeness"`
	DependencyState map[string]string `json:"dependencyState"`
	Version         *string           `json:"version,omitempty"`
	StartedAt       time.Time         `json:"startedAt"`
	HeartbeatAt     time.Time         `json:"heartbeatAt"`
}

func (s *PostgresStore) ListServiceStates(ctx context.Context) ([]ServiceState, error) {
	// A heartbeat alone cannot grant coordinator authority. Compare its durable
	// owner and fencing token with the unexpired, unreleased role lease on every read.
	rows, err := s.DB.Query(ctx, `SELECT state.service,state.environment,state.instance_id,state.liveness,state.readiness,state.freshness,state.completeness,
 (CASE WHEN state.service='coordinator-appview' THEN state.dependency_state || jsonb_build_object('coordinator_authority',CASE WHEN
 lease.owner_id=state.dependency_state->>'coordinator_owner_id' AND lease.fencing_token::text=state.dependency_state->>'coordinator_fencing_token'
 AND lease.role=state.dependency_state->>'coordinator_role' AND lease.released_at IS NULL AND lease.lease_expires_at>clock_timestamp()
 THEN 'active' ELSE 'inactive' END) ELSE state.dependency_state END)::text,
 state.version,state.started_at,state.heartbeat_at FROM operations_service_state state
 LEFT JOIN operations_role_leases lease ON lease.environment=state.environment AND lease.role='indexing.appview-coordinator'
 WHERE state.environment=$1 AND state.heartbeat_at>NOW()-INTERVAL '2 minutes' ORDER BY state.service,state.heartbeat_at DESC`, s.Environment)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	states := []ServiceState{}
	for rows.Next() {
		var state ServiceState
		var dependencies string
		if err = rows.Scan(&state.Service, &state.Environment, &state.InstanceID, &state.Liveness, &state.Readiness, &state.Freshness, &state.Completeness, &dependencies, &state.Version, &state.StartedAt, &state.HeartbeatAt); err != nil {
			return nil, err
		}
		for _, field := range []*string{&state.Liveness, &state.Readiness, &state.Freshness, &state.Completeness} {
			switch *field {
			case "healthy", "degraded", "unhealthy", "unknown":
			default:
				*field = "unknown"
			}
		}
		if json.Unmarshal([]byte(dependencies), &state.DependencyState) != nil || state.DependencyState == nil {
			state.DependencyState = map[string]string{}
		}
		states = append(states, state)
	}
	return states, rows.Err()
}
func freshWorker(service string, states []ServiceState, now time.Time, validity time.Duration) *ServiceState {
	var found *ServiceState
	for _, state := range states {
		age := now.Sub(state.HeartbeatAt)
		if state.Service == service && age >= -time.Second && age <= validity && (found == nil || state.HeartbeatAt.After(found.HeartbeatAt)) {
			copy := state
			found = &copy
		}
	}
	return found
}
func RecoveryWorker(states []ServiceState, now time.Time) *ServiceState {
	coordinatorPresent := false
	active := []ServiceState{}
	for _, state := range states {
		if state.Service == "coordinator-appview" {
			coordinatorPresent = true
			if state.DependencyState["coordinator_authority"] == "active" && state.DependencyState["coordinator_role"] == "indexing.appview-coordinator" {
				active = append(active, state)
			}
		}
	}
	if coordinatorPresent {
		return freshWorker("coordinator-appview", active, now, 15*time.Second)
	}
	return freshWorker("appview-worker", states, now, 15*time.Second)
}
