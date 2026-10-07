package operationsapi

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"testing"
	"time"
)

func TestRetentionRoundsBoundWorkAndPreserveFailedProgress(t *testing.T) {
	calls := 0
	round, e := RunRetentionRound(context.Background(), func(context.Context, time.Time, int) (int64, error) { calls++; return 1000, nil }, time.Now)
	if e != nil || round.Drained || round.Calls != 10 || round.Deleted != 10000 || calls != 10 {
		t.Fatal(round, e, calls)
	}
	calls = 0
	round, e = RunRetentionRound(context.Background(), func(context.Context, time.Time, int) (int64, error) {
		calls++
		if calls == 2 {
			return 0, nil
		}
		return 1000, nil
	}, time.Now)
	if e != nil || !round.Drained || round.Calls != 2 || round.Deleted != 1000 {
		t.Fatal(round, e)
	}
	calls = 0
	round, e = RunRetentionRound(context.Background(), func(context.Context, time.Time, int) (int64, error) {
		calls++
		if calls == 2 {
			return 0, errors.New("unavailable")
		}
		return 1000, nil
	}, time.Now)
	if e == nil || round.Drained || round.Deleted != 1000 || calls != 2 {
		t.Fatal(round, e, calls)
	}
	for n, expected := range []time.Duration{5, 10, 20, 40, 60, 60} {
		if RetentionFailureDelay(n+1) != expected*time.Second {
			t.Fatal(n)
		}
	}
}
func TestAlertRulesRespectDurableAuthorityAndActionableAge(t *testing.T) {
	at := time.Now().UTC()
	config, _ := ConfigFromEnvironment(map[string]string{"APP_ENV": "dev", "DATABASE_URL": "fixture"})
	checkpoint := DurabilityCheckpoint{Environment: "dev", SourceGeneration: "current", CursorKind: "jetstream_v2_seq", ReplayState: "live", IntakeHeartbeatAt: &WireTime{at}, UpdatedAt: WireTime{at}}
	input := AlertEvaluationInput{Services: []ServiceState{{Service: "projection-pool-appview", Environment: "dev", HeartbeatAt: at, DependencyState: map[string]string{"ingestion_authority": DurableJetstreamV2AuthoritySource, "jetstream_v2_source_generation": "current"}}}, Durability: &DurabilitySnapshot{Environment: "dev", GeneratedAt: WireTime{at}, Checkpoints: []DurabilityCheckpoint{checkpoint}, InboxBySourceGeneration: map[string]InboxMetrics{"current": {Pending: 1, OldestPendingAgeSeconds: pointer(61.0)}}}}
	find := func(rules []AlertCondition, key string) AlertCondition {
		t.Helper()
		for _, r := range rules {
			if r.Key == key {
				return r
			}
		}
		t.Fatal("missing", key)
		return AlertCondition{}
	}
	rules := EvaluateAlertConditions(input, config, at)
	if find(rules, "jetstream:transport_evidence_missing").Active || find(rules, "jetstream:queue_evidence_missing").Active || find(rules, DurableJetstreamV2AuthoritySource+":transport_evidence_missing").Active {
		t.Fatal("durable authority used legacy or invalid identity")
	}
	r := find(rules, "jetstream_v2_inbox:actionable_backlog_overdue")
	if !r.Active || r.Severity != "warning" {
		t.Fatal(r)
	}
	input.Durability.InboxBySourceGeneration["current"] = InboxMetrics{Pending: 1, OldestPendingAgeSeconds: pointer(901.0)}
	rules = EvaluateAlertConditions(input, config, at)
	if r = find(rules, "jetstream_v2_inbox:actionable_backlog_overdue"); !r.Active || r.Severity != "critical" {
		t.Fatal(r)
	}
	input.Durability.Checkpoints[0].ReplayState = "snapshot_complete"
	input.Durability.Checkpoints[0].IntakeHeartbeatAt = nil
	rules = EvaluateAlertConditions(input, config, at)
	if find(rules, DurableJetstreamV2AuthoritySource+":transport_heartbeat_expired").Active || find(rules, DurableJetstreamV2AuthoritySource+":transport_evidence_missing").Active {
		t.Fatal("terminal snapshot needs live lease")
	}
	input.Services[0].HeartbeatAt = at.Add(-16 * time.Second)
	rules = EvaluateAlertConditions(input, config, at)
	if !find(rules, "ingestion:authority_evidence_missing").Active || !find(rules, "jetstream:transport_evidence_missing").Active {
		t.Fatal("stale worker evidence granted durable authority")
	}
}
func TestLegacyBacklogRequiresBothExactQueueAndCurrentTransport(t *testing.T) {
	at := time.Now()
	config, _ := ConfigFromEnvironment(map[string]string{"APP_ENV": "dev", "DATABASE_URL": "fixture"})
	state := StreamState{LastReceivedCursor: pointer(int64(100000000)), LastCommittedCursor: pointer(int64(0)), TransportHeartbeatAt: &WireTime{at}, QueueEvidence: &EvidenceMetadata{Accuracy: "sampled", IndexedThrough: &WireTime{at}, ValidUntil: WireTime{at.Add(time.Second)}}}
	rules := legacyBacklogConditions(&state, true, config, at)
	if !rules[0].Active || rules[2].Active {
		t.Fatal(rules)
	}
	state.QueueEvidence.Accuracy = "exact"
	rules = legacyBacklogConditions(&state, true, config, at)
	if rules[0].Active || !rules[2].Active {
		t.Fatal(rules)
	}
	rules = legacyBacklogConditions(&state, true, config, at.Add(time.Second))
	if !rules[1].Active || rules[2].Active {
		t.Fatal(rules)
	}
}
func TestTelemetryHeartbeatKeepsLossDistinctFromExportRecovery(t *testing.T) {
	at := time.Now()
	s := telemetrycore.TelemetrySnapshot{Capacity: 10, Dropped: 1, LastDrop: pointer(at.Add(-time.Minute)), LastSuccess: &at}
	evidence := telemetryHeartbeatEvidence(s, at)
	if evidence["telemetry_exporter"] != "degraded" || evidence["telemetry_loss_state"] != "unrecovered" {
		t.Fatal(evidence)
	}
	s.LastRecovered = &at
	evidence = telemetryHeartbeatEvidence(s, at)
	if evidence["telemetry_loss_state"] != "recovered" || evidence["telemetry_exporter"] != "idle" {
		t.Fatal(evidence)
	}
}
