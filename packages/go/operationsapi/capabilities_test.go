package operationsapi

import (
	"context"
	"errors"
	"testing"
	"time"
)

type capabilityFixture struct {
	states []ServiceState
	err    error
}

func (s capabilityFixture) ChangeEventCursorBounds(context.Context) (ChangeEventCursorBounds, error) {
	return ChangeEventCursorBounds{1, 0}, s.err
}
func (s capabilityFixture) ListServiceStates(context.Context) ([]ServiceState, error) {
	return s.states, s.err
}
func TestCapabilitiesRequireFreshFencedCoordinatorAndReleaseGates(t *testing.T) {
	now := time.Now()
	worker := ServiceState{Service: "coordinator-appview", HeartbeatAt: now, DependencyState: map[string]string{"coordinator_authority": "active", "coordinator_role": "indexing.appview-coordinator", "operations_database": "ready", "appview_database": "ready", "jetstream_replay": "enabled_durable_v2", "pds_reconciliation": "enabled_diagnostic_only"}}
	config := Config{Environment: "dev", Enabled: true, RecoveryEnabled: true, FingerprintSecret: "fixture"}
	result := ResolveCapabilities(context.Background(), capabilityFixture{states: []ServiceState{worker}}, config, now)
	if !result.Recovery.Enabled || !result.RecoveryModes.JetstreamReplay.Enabled || !result.RecoveryModes.PDSReconciliation.Enabled || result.RecoveryModes.TapVerifiedResync.Enabled || !result.EventStream.Enabled {
		t.Fatal(result)
	}
	for _, change := range []func(*ServiceState, *Config){func(s *ServiceState, c *Config) { c.RecoveryEnabled = false }, func(s *ServiceState, c *Config) { c.FingerprintSecret = "" }, func(s *ServiceState, c *Config) { s.HeartbeatAt = now.Add(-16 * time.Second) }, func(s *ServiceState, c *Config) { s.DependencyState["coordinator_authority"] = "inactive" }, func(s *ServiceState, c *Config) { s.DependencyState["coordinator_role"] = "wrong" }, func(s *ServiceState, c *Config) { s.DependencyState["appview_database"] = "unknown" }} {
		copy := worker
		copy.DependencyState = map[string]string{}
		for k, v := range worker.DependencyState {
			copy.DependencyState[k] = v
		}
		c := config
		change(&copy, &c)
		result = ResolveCapabilities(context.Background(), capabilityFixture{states: []ServiceState{copy}}, c, now)
		if result.Recovery.Enabled || result.RecoveryModes.JetstreamReplay.Enabled || result.RecoveryModes.PDSReconciliation.Enabled {
			t.Fatal("authority bypass", result)
		}
	}
	standby := worker
	standby.DependencyState = map[string]string{"coordinator_authority": "inactive"}
	legacy := worker
	legacy.Service = "appview-worker"
	if RecoveryWorker([]ServiceState{standby, legacy}, now) != nil {
		t.Fatal("legacy worker bypassed consolidated coordinator")
	}
	result = ResolveCapabilities(context.Background(), capabilityFixture{err: errors.New("store unavailable")}, config, now)
	if result.EventStream.Enabled || result.Recovery.Enabled {
		t.Fatal("failed store enabled capability")
	}
}
