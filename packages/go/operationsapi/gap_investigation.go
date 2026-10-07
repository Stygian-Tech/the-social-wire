package operationsapi

import (
	"context"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

type GapInvestigation struct {
	Gap                Gap                        `json:"gap"`
	WindowStart        WireTime                   `json:"windowStart"`
	WindowEnd          WireTime                   `json:"windowEnd"`
	Assessment         GapCauseAssessment         `json:"assessment"`
	Evidence           []GapInvestigationEvidence `json:"evidence"`
	RecommendedActions []string                   `json:"recommendedActions"`
}

func BuildGapInvestigation(gap Gap, events []TelemetryEvent, spans []TraceSpan, services []ServiceState, alerts []Alert) GapInvestigation {
	start, end := gap.DetectedAt.Add(-10*time.Minute), gap.DetectedAt.Add(10*time.Minute)
	cursor := func(value *int64) string {
		if value == nil {
			return "unknown"
		}
		return strconv.FormatInt(*value, 10)
	}
	evidence := []GapInvestigationEvidence{{ID: "gap-detected", Kind: "gap", OccurredAt: gap.DetectedAt, Service: gap.Source, Title: "Gap detected", Detail: strings.ReplaceAll(gap.Reason, "_", " "), Attributes: map[string]string{"start_cursor": cursor(gap.StartCursor), "end_cursor": cursor(gap.EndCursor)}}}
	for _, event := range events {
		title, detail, kind := strings.ReplaceAll(event.Name, ".", " "), "Recorded worker lifecycle event.", "stream"
		switch event.Name {
		case "commit.failed":
			title, detail, kind = "Commit indexing failed", fallbackAttribute(event.Attributes, "error_type", "The worker recorded a redacted indexing error."), "indexing"
		case "jetstream.disconnected":
			title, detail = "Jetstream disconnected", fallbackAttribute(event.Attributes, "error_type", "The worker lost its Jetstream connection.")
		case "jetstream.connected":
			title, detail = "Jetstream connected", "The worker established a Jetstream connection."
		}
		evidence = append(evidence, GapInvestigationEvidence{ID: "event-" + event.ID, Kind: kind, OccurredAt: event.OccurredAt, Service: event.Service, Title: title, Detail: detail, Attributes: event.Attributes, TraceID: event.TraceID})
	}
	for _, span := range spans {
		if strings.ToLower(span.Status) == "error" || strings.HasPrefix(span.Status, "5") {
			duration := span.DurationMS
			if math.IsNaN(duration) || math.IsInf(duration, 0) {
				duration = 0
			}
			evidence = append(evidence, GapInvestigationEvidence{ID: "span-" + span.ID, Kind: "trace", OccurredAt: span.StartedAt, Service: span.Service, Title: "Error trace: " + span.Name, Detail: "The operation failed after " + strconv.FormatFloat(math.Trunc(duration), 'f', 0, 64) + " ms.", Attributes: span.Attributes, TraceID: &span.TraceID})
		}
	}
	for _, service := range services {
		if !service.StartedAt.Before(start) && !service.StartedAt.After(end) {
			detail := "Instance " + service.InstanceID + " started."
			version := "unknown"
			if service.Version != nil {
				version = *service.Version
				detail = "Instance " + service.InstanceID + " started with image " + version + "."
			}
			evidence = append(evidence, GapInvestigationEvidence{ID: "service-" + service.InstanceID, Kind: "service", OccurredAt: WireTime{service.StartedAt}, Service: service.Service, Title: "Service instance started", Detail: detail, Attributes: map[string]string{"instance_id": service.InstanceID, "version": version}})
		}
	}
	for _, alert := range alerts {
		if !alert.OpenedAt.Before(start) && !alert.OpenedAt.After(end) {
			evidence = append(evidence, GapInvestigationEvidence{ID: "alert-" + alert.ID, Kind: "alert", OccurredAt: alert.OpenedAt, Service: "operations", Title: "Alert: " + strings.ReplaceAll(alert.Rule, "_", " "), Detail: alert.Summary, Attributes: alert.Evidence})
		}
	}
	sort.SliceStable(evidence, func(i, j int) bool { return evidence[i].OccurredAt.Before(evidence[j].OccurredAt.Time) })
	assessment := assessGapCause(gap, events, evidence)
	actions := []string{"Verify the proposed recovery scope against the gap cursor range before running a backfill."}
	for _, item := range evidence {
		if item.TraceID != nil {
			actions = append(actions, "Open the correlated error trace and inspect its recorded attributes.")
			break
		}
	}
	if assessment.Confidence != "high" {
		actions = append(actions, "Compare the window with Railway deployment and replica restart history; deployment events are not yet ingested here.")
	}
	return GapInvestigation{Gap: gap, WindowStart: WireTime{start}, WindowEnd: WireTime{end}, Assessment: assessment, Evidence: evidence, RecommendedActions: actions}
}
func fallbackAttribute(values map[string]string, key, fallback string) string {
	if value, exists := values[key]; exists {
		return value
	}
	return fallback
}
func assessGapCause(gap Gap, events []TelemetryEvent, evidence []GapInvestigationEvidence) GapCauseAssessment {
	limitation := "This assessment correlates recorded signals; it cannot prove an unobserved upstream or infrastructure root cause."
	assessment := func(title, confidence, summary string, ids []string, extra string) GapCauseAssessment {
		limits := []string{limitation}
		if extra != "" {
			limits = append(limits, extra)
		}
		return GapCauseAssessment{Title: title, Confidence: confidence, Summary: summary, EvidenceIDs: ids, Limitations: limits}
	}
	if gap.Reason == "message_pump_overflow" {
		return assessment("Worker message pump overflow", "high", "The gap detector recorded a message-pump overflow, meaning the worker could not drain received Jetstream messages before its bounded queue filled.", []string{"gap-detected"}, "")
	}
	failures, disconnects, reconnects := []TelemetryEvent{}, []TelemetryEvent{}, []TelemetryEvent{}
	for _, event := range events {
		switch event.Name {
		case "commit.failed":
			failures = append(failures, event)
		case "jetstream.disconnected":
			disconnects = append(disconnects, event)
		case "jetstream.connected":
			reconnects = append(reconnects, event)
		}
	}
	if len(failures) > 0 {
		failure := failures[len(failures)-1]
		confidence, ending := "medium", " during the gap window."
		ids := []string{"event-" + failure.ID}
		for _, disconnect := range disconnects {
			if math.Abs(disconnect.OccurredAt.Sub(failure.OccurredAt.Time).Seconds()) <= 60 {
				confidence, ending = "high", " immediately before the Jetstream connection was restarted."
				ids = append(ids, "event-"+disconnect.ID)
				break
			}
		}
		return assessment("Indexing failure interrupted commit advancement", confidence, "The worker recorded a commit failure ("+fallbackAttribute(failure.Attributes, "error_type", "redacted error")+")"+ending, ids, "Error details are deliberately redacted to a bounded category in operations telemetry.")
	}
	if len(disconnects) > 0 {
		disconnect := disconnects[len(disconnects)-1]
		confidence, ending := "low", "."
		for _, reconnect := range reconnects {
			if !reconnect.OccurredAt.Before(disconnect.OccurredAt.Time) {
				confidence, ending = "medium", " and subsequently reconnected."
				break
			}
		}
		return assessment("Jetstream connection interruption", confidence, "The worker recorded a Jetstream disconnect ("+fallbackAttribute(disconnect.Attributes, "error_type", "unknown error")+") during the gap window"+ending, []string{"event-" + disconnect.ID}, "The disconnect category may describe the symptom rather than the underlying network or dependency failure.")
	}
	for _, item := range evidence {
		if item.Kind == "service" && item.Title == "Service instance started" {
			return assessment("Worker instance restart", "medium", "Charybdis started inside the gap window, making a restart or deployment a plausible contributor.", []string{item.ID}, "The current service-state record does not distinguish a deployment from an infrastructure restart.")
		}
	}
	if gap.Reason == "receive_commit_backlog" {
		return assessment("Receive-to-commit backlog at disconnect", "low", "The worker had received events that were not durably committed when the stream disconnected. The triggering failure was not retained in the available evidence.", []string{"gap-detected"}, "No correlated failure, disconnect event, or restart was retained for this window.")
	}
	return assessment("Cause not determined from retained telemetry", "insufficient", "The gap is confirmed, but the available lifecycle events, error spans, alerts, and service starts do not identify a supported trigger.", []string{"gap-detected"}, "Deployment history and external provider incidents are not currently ingested into the Operations store.")
}
func (s *PostgresStore) InvestigateGap(ctx context.Context, id string) (*GapInvestigation, error) {
	gap, err := s.FetchGap(ctx, id)
	if err != nil || gap == nil {
		return nil, err
	}
	start, end := gap.DetectedAt.Add(-10*time.Minute), gap.DetectedAt.Add(10*time.Minute)
	events, err := s.ListGapInvestigationEvents(ctx, start, end, 500)
	if err != nil {
		return nil, err
	}
	spans, err := s.ListTraceSpansWindow(ctx, start, end, 250)
	if err != nil {
		return nil, err
	}
	services, err := s.ListServiceStates(ctx)
	if err != nil {
		return nil, err
	}
	alerts, err := s.ListAlerts(ctx, "all", 250, nil)
	if err != nil {
		return nil, err
	}
	investigation := BuildGapInvestigation(*gap, events, spans, services, alerts.Items)
	return &investigation, nil
}
