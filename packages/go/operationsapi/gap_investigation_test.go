package operationsapi

import (
	"testing"
	"time"
)

func TestGapInvestigationSeparatesCorrelationFromUnsupportedCause(t *testing.T) {
	at := time.Now().UTC()
	gap := Gap{Source: "jetstream", Reason: "receive_commit_backlog", DetectedAt: WireTime{at}}
	for _, test := range []struct {
		reason            string
		events            []TelemetryEvent
		title, confidence string
	}{{"message_pump_overflow", nil, "Worker message pump overflow", "high"}, {"receive_commit_backlog", []TelemetryEvent{{ID: "failure", Name: "commit.failed", OccurredAt: WireTime{at}, Attributes: map[string]string{"error_type": "fixture"}}, {ID: "disconnect", Name: "jetstream.disconnected", OccurredAt: WireTime{at.Add(30 * time.Second)}}}, "Indexing failure interrupted commit advancement", "high"}, {"receive_commit_backlog", []TelemetryEvent{{ID: "failure", Name: "commit.failed", OccurredAt: WireTime{at}}}, "Indexing failure interrupted commit advancement", "medium"}, {"receive_commit_backlog", []TelemetryEvent{{ID: "disconnect", Name: "jetstream.disconnected", OccurredAt: WireTime{at}}, {ID: "connect", Name: "jetstream.connected", OccurredAt: WireTime{at.Add(time.Minute)}}}, "Jetstream connection interruption", "medium"}, {"receive_commit_backlog", nil, "Receive-to-commit backlog at disconnect", "low"}, {"unknown", nil, "Cause not determined from retained telemetry", "insufficient"}} {
		gap.Reason = test.reason
		result := BuildGapInvestigation(gap, test.events, nil, nil, nil)
		if result.Assessment.Title != test.title || result.Assessment.Confidence != test.confidence || len(result.Assessment.Limitations) == 0 {
			t.Fatal(result)
		}
		if result.WindowStart.Time != at.Add(-10*time.Minute) || result.WindowEnd.Time != at.Add(10*time.Minute) {
			t.Fatal("investigation window drift", result)
		}
	}
	gap.Reason = "unknown"
	services := []ServiceState{{Service: "fixture", InstanceID: "restart", StartedAt: at}, {Service: "outside", InstanceID: "old", StartedAt: at.Add(-11 * time.Minute)}}
	span := TraceSpan{ID: "error", TraceID: "trace", Status: "ERROR", StartedAt: WireTime{at.Add(-time.Second)}, DurationMS: 2.75}
	result := BuildGapInvestigation(gap, nil, []TraceSpan{span}, services, nil)
	if result.Assessment.Title != "Worker instance restart" || len(result.Evidence) != 3 || result.Evidence[0].ID != "span-error" || len(result.RecommendedActions) != 3 {
		t.Fatal(result)
	}
}
