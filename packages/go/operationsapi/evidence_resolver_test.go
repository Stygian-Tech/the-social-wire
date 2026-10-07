package operationsapi

import (
	"testing"
	"time"
)

func TestEvidenceRejectsLegacyFallbackAndStaleDurableAuthority(t *testing.T) {
	at := time.Now().UTC()
	services := []ServiceState{{Service: "appview-worker", Environment: "dev", HeartbeatAt: at, DependencyState: map[string]string{"ingestion_authority": "jetstream"}}, {Service: "projection-pool-appview", Environment: "dev", HeartbeatAt: at.Add(-16 * time.Second), DependencyState: map[string]string{"ingestion_authority": DurableJetstreamV2AuthoritySource}}}
	authority := ResolveIngestionAuthority(services, nil, nil, at)
	if authority.Source != nil || authority.Evidence.Accuracy != "unavailable" {
		t.Fatal("stale consolidated evidence fell back", authority)
	}
	services[1].HeartbeatAt = at
	services[1].DependencyState["jetstream_v2_source_generation"] = "current"
	checkpoint := DurabilityCheckpoint{Environment: "dev", SourceGeneration: "wrong", CursorKind: "jetstream_v2_seq", ReplayState: "live", IntakeHeartbeatAt: &WireTime{at}, UpdatedAt: WireTime{at}}
	snapshot := DurabilitySnapshot{Environment: "dev", GeneratedAt: WireTime{at}, Checkpoints: []DurabilityCheckpoint{checkpoint}, InboxBySourceGeneration: map[string]InboxMetrics{"current": {Pending: 3, Retrying: 2}}}
	authority = ResolveIngestionAuthority(services, nil, &snapshot, at)
	if authority.State != nil || authority.Evidence.Accuracy != "unavailable" {
		t.Fatal("mismatched generation granted authority", authority)
	}
	snapshot.Checkpoints[0].SourceGeneration = "current"
	authority = ResolveIngestionAuthority(services, nil, &snapshot, at)
	if authority.State == nil || authority.State.QueueDepth != 5 || authority.Evidence.Accuracy != "exact" {
		t.Fatal(authority)
	}
	snapshot.Checkpoints[0].IntakeHeartbeatAt = &WireTime{at.Add(-46 * time.Second)}
	authority = ResolveIngestionAuthority(services, nil, &snapshot, at)
	if authority.Evidence.Accuracy != "unavailable" || authority.Evidence.IndexedThrough != nil {
		t.Fatal("stale lease reported fresh", authority)
	}
	snapshot.Checkpoints[0].ReplayState = "snapshot_complete"
	snapshot.Checkpoints[0].IntakeHeartbeatAt = nil
	authority = ResolveIngestionAuthority(services, nil, &snapshot, at)
	if authority.Evidence.Accuracy != "exact" || authority.Evidence.ValidUntil.Year() != 4001 {
		t.Fatal("terminal snapshot not recognized", authority)
	}
	required := []ServiceState{}
	for _, name := range []string{"gateway", "appview", "operations"} {
		required = append(required, ServiceState{Service: name, HeartbeatAt: at})
	}
	required = append(required, ServiceState{Service: "projection-pool-appview", HeartbeatAt: at}, ServiceState{Service: "coordinator-appview", HeartbeatAt: at, DependencyState: map[string]string{"coordinator_role": "indexing.appview-coordinator", "coordinator_authority": "inactive"}})
	evidence := ServiceEvidence(required, at)
	if evidence.Accuracy != "sampled" || *evidence.Coverage != 0.75 {
		t.Fatal(evidence)
	}
	required[len(required)-1].DependencyState["coordinator_authority"] = "active"
	evidence = ServiceEvidence(required, at)
	if evidence.Accuracy != "exact" || evidence.DegradedReason != nil || *evidence.Coverage != 1 {
		t.Fatal(evidence)
	}
}
