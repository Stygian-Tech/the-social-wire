package operationsapi

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strconv"
	"time"
)

const durableInboxDegradedAgeSeconds = 60
const durableInboxUnhealthyAgeSeconds = 15 * 60

type AlertCondition struct {
	Active                                bool
	Rule, Key, Severity, Summary, Runbook string
	Evidence                              map[string]string
}

type AlertEvaluationInput struct {
	Services                            []ServiceState
	Streams                             []StreamState
	Durability                          *DurabilitySnapshot
	Counts                              LifecycleCounts
	ActiveBackfills, AttentionBackfills []BackfillJob
	Results, Requests                   []MetricRollup
}

func EvaluateAlertConditions(input AlertEvaluationInput, config Config, at time.Time) []AlertCondition {
	rules := []AlertCondition{}
	appendRule := func(active bool, rule, key, severity, summary, runbook string, evidence map[string]string) {
		rules = append(rules, AlertCondition{active, rule, key, severity, summary, runbook, evidence})
	}
	resolve := func(keys ...string) {
		for _, key := range keys {
			appendRule(false, "", key, "", "", "", nil)
		}
	}
	authority := ResolveIngestionAuthority(input.Services, input.Streams, input.Durability, at)
	worker := IngestionWorker(input.Services, at)
	workerAt := "none"
	workerUntil := "none"
	if worker != nil {
		workerAt = worker.HeartbeatAt.UTC().Format(time.RFC3339)
		workerUntil = worker.HeartbeatAt.Add(15 * time.Second).UTC().Format(time.RFC3339)
	}
	appendRule(authority.Source == nil, "ingestion_authority_evidence_missing", "ingestion:authority_evidence_missing", "critical", "No fresh ingestion-authority capability evidence is available.", "live-process-stalled-ingestion", map[string]string{"worker_heartbeat_at": workerAt, "observedAt": workerAt, "validUntil": workerUntil})
	sources := map[string]*StreamState{}
	for _, stream := range input.Streams {
		s := stream
		sources[s.Source] = &s
	}
	evaluated := map[string]bool{}
	for source := range sources {
		if source != "tap" && source != DurableJetstreamV2AuthoritySource {
			evaluated[source] = true
		}
	}
	durable := authority.Source != nil && *authority.Source == DurableJetstreamV2AuthoritySource
	transportKeys := func(source string) []string {
		return []string{source + ":transport_evidence_missing", source + ":transport_heartbeat_expired", source + ":transport_disconnected"}
	}
	legacyBacklogKeys := []string{"jetstream:queue_evidence_missing", "jetstream:queue_evidence_expired", "jetstream:commit_backlog"}
	durableTransportKeys := []string{DurableJetstreamV2AuthoritySource + ":transport_evidence_missing", DurableJetstreamV2AuthoritySource + ":transport_heartbeat_expired", DurableJetstreamV2AuthoritySource + ":replay_failed"}
	if durable {
		delete(evaluated, "jetstream")
		resolve(transportKeys("jetstream")...)
		resolve(legacyBacklogKeys...)
		checkpoint := authority.DurableCheckpoint
		terminal := checkpoint != nil && checkpoint.ReplayState == "snapshot_complete"
		var observed *WireTime
		identity := false
		evidence := map[string]string{"source_generation": "none", "source_host": "none", "cursor_kind": "none", "replay_state": "none", "snapshot_complete": strconv.FormatBool(terminal), "replay_after_sequence": "none", "replay_before_sequence": "none", "replay_sealed_sequence": "none", "last_staged_sequence": "none", "last_applied_sequence": "none", "checkpoint_updated_at": "none", "observedAt": "none", "validUntil": "none"}
		if checkpoint != nil {
			observed = checkpoint.IntakeHeartbeatAt
			if terminal {
				observed = &checkpoint.UpdatedAt
			}
			identity = checkpoint.CursorKind == "jetstream_v2_seq"
			evidence["source_generation"] = checkpoint.SourceGeneration
			evidence["source_host"] = checkpoint.SourceHost
			evidence["cursor_kind"] = checkpoint.CursorKind
			evidence["replay_state"] = checkpoint.ReplayState
			evidence["replay_after_sequence"] = optionalInt64(checkpoint.ReplayAfterSequence, "none")
			evidence["replay_before_sequence"] = optionalInt64(checkpoint.ReplayBeforeSequence, "none")
			evidence["replay_sealed_sequence"] = optionalInt64(checkpoint.ReplaySealedSequence, "none")
			evidence["last_staged_sequence"] = optionalInt64(checkpoint.LastStagedSequence, "none")
			evidence["last_applied_sequence"] = optionalInt64(checkpoint.LastAppliedSequence, "none")
			evidence["checkpoint_updated_at"] = checkpoint.UpdatedAt.UTC().Format(time.RFC3339)
		}
		if observed != nil {
			evidence["observedAt"] = formatOptionalTime(observed, "none")
			evidence["validUntil"] = observed.Add(config.IdleAlert).UTC().Format(time.RFC3339)
		}
		appendRule(checkpoint == nil || !identity || !terminal && observed == nil, "jetstream_v2_transport_evidence_missing", durableTransportKeys[0], "critical", "No matching durable Jetstream V2 checkpoint evidence is available for the authority source.", "live-process-stalled-ingestion", evidence)
		expired := !terminal && identity && observed != nil && (at.Sub(observed.Time) < 0 || at.Sub(observed.Time) >= config.IdleAlert)
		appendRule(expired, "jetstream_v2_transport_heartbeat_expired", durableTransportKeys[1], "critical", "The durable Jetstream V2 intake lease heartbeat has expired for the authority source.", "live-process-stalled-ingestion", evidence)
		appendRule(checkpoint != nil && checkpoint.ReplayState == "failed", "jetstream_v2_replay_failed", durableTransportKeys[2], "critical", "The authoritative durable Jetstream V2 replay is in a failed state.", "live-process-stalled-ingestion", evidence)
		backlog := authority.DurableInbox
		if backlog == nil || backlog.OldestPendingAgeSeconds == nil || *backlog.OldestPendingAgeSeconds <= durableInboxDegradedAgeSeconds {
			resolve("jetstream_v2_inbox:actionable_backlog_overdue")
		} else {
			age := *backlog.OldestPendingAgeSeconds
			severity, summary, threshold := "warning", "The authoritative Jetstream V2 inbox has actionable work older than 60 seconds.", float64(durableInboxDegradedAgeSeconds)
			if age > durableInboxUnhealthyAgeSeconds {
				severity = "critical"
				summary = "The authoritative Jetstream V2 inbox has actionable work older than 15 minutes."
				threshold = durableInboxUnhealthyAgeSeconds
			}
			b := map[string]string{"source_generation": "none", "replay_state": "none", "pending_count": strconv.Itoa(backlog.Pending), "leased_count": strconv.Itoa(backlog.Leased), "retrying_count": strconv.Itoa(backlog.Retrying), "oldest_actionable_age_seconds": fmt.Sprint(age), "threshold_seconds": fmt.Sprint(threshold), "observedAt": "none", "validUntil": "none"}
			if checkpoint != nil {
				b["source_generation"] = checkpoint.SourceGeneration
				b["replay_state"] = checkpoint.ReplayState
			}
			if input.Durability != nil {
				b["observedAt"] = input.Durability.GeneratedAt.UTC().Format(time.RFC3339)
				b["validUntil"] = input.Durability.GeneratedAt.Add(5 * time.Second).UTC().Format(time.RFC3339)
			}
			appendRule(true, "jetstream_v2_actionable_backlog_overdue", "jetstream_v2_inbox:actionable_backlog_overdue", severity, summary, "live-process-stalled-ingestion", b)
		}
	} else {
		evaluated["jetstream"] = true
		resolve(durableTransportKeys...)
		resolve("jetstream_v2_inbox:actionable_backlog_overdue")
	}
	tapEnabled := worker != nil && (worker.DependencyState["tap_role"] == "shadow" || worker.DependencyState["tap_role"] == "authoritative")
	if tapEnabled {
		evaluated["tap"] = true
	} else {
		resolve(transportKeys("tap")...)
	}
	names := []string{}
	for source := range evaluated {
		names = append(names, source)
	}
	sort.Strings(names)
	for _, source := range names {
		state := sources[source]
		isAuthority := authority.Source != nil && *authority.Source == source
		severity, role := "warning", "supplemental"
		if isAuthority {
			severity = "critical"
			role = "authority"
		}
		display := source
		if source == "jetstream" {
			display = "Jetstream"
		}
		if source == "tap" {
			display = "Tap"
		}
		var observed *WireTime
		if state != nil {
			observed = state.TransportHeartbeatAt
		}
		evidence := map[string]string{"transport_heartbeat_at": formatOptionalTime(observed, "none"), "role": role, "observedAt": formatOptionalTime(observed, "none"), "validUntil": "none"}
		if observed != nil {
			evidence["validUntil"] = observed.Add(config.IdleAlert).UTC().Format(time.RFC3339)
		}
		keys := transportKeys(source)
		appendRule(observed == nil, source+"_transport_evidence_missing", keys[0], severity, "No "+display+" transport heartbeat evidence is available for the "+role+" source.", "live-process-stalled-ingestion", evidence)
		appendRule(observed != nil && at.Sub(observed.Time) >= config.IdleAlert, source+"_transport_heartbeat_expired", keys[1], severity, "The "+display+" transport heartbeat has expired for the "+role+" source.", "live-process-stalled-ingestion", evidence)
		disconnected := false
		connection := "unknown"
		if state != nil {
			connection = state.ConnectionState
			last := state.LastDisconnectAt
			if last == nil {
				last = state.TransportHeartbeatAt
			}
			if last == nil {
				last = &state.HeartbeatAt
			}
			disconnected = connection != "connected" && at.Sub(last.Time) >= config.DisconnectAlert
		}
		disconnectEvidence := map[string]string{}
		for k, v := range evidence {
			disconnectEvidence[k] = v
		}
		disconnectEvidence["connection_state"] = connection
		runbook := "tap-shadow-and-cutover"
		if source == "jetstream" {
			runbook = "jetstream-disconnect-reconnect"
		}
		appendRule(disconnected, source+"_disconnected", keys[2], severity, display+" has remained disconnected as the "+role+" source.", runbook, disconnectEvidence)
	}
	if !durable {
		rules = append(rules, legacyBacklogConditions(sources["jetstream"], authority.Source != nil && *authority.Source == "jetstream", config, at)...)
	}
	gapRisk := input.Counts.ActiveGaps > 0
	gapRule, gapSummary := "active_ingestion_gap", "Legacy ingestion gap evidence requires investigation."
	evidence := map[string]string{"open_incident_count": "unavailable", "dead_letter_count": "unavailable", "legacy_gap_signal_count": strconv.Itoa(input.Counts.ActiveGaps), "primary_evidence": "legacy_gap_signals"}
	if d := input.Durability; d != nil {
		incidents := d.Incidents.Open + d.Incidents.Recovering + d.Incidents.VerificationRequired
		gapRisk = incidents > 0 || d.Inbox.DeadLetters > 0
		gapRule = "active_ingestion_incident"
		gapSummary = "A durable ingestion incident or dead letter requires recovery."
		evidence["open_incident_count"] = strconv.Itoa(incidents)
		evidence["dead_letter_count"] = strconv.Itoa(d.Inbox.DeadLetters)
		evidence["primary_evidence"] = "durable_ingestion"
	}
	appendRule(gapRisk, gapRule, "ingestion:active_gap", "critical", gapSummary, "confirming-and-scoping-a-gap", evidence)
	stalled, failed := 0, 0
	for _, v := range input.ActiveBackfills {
		if v.Status == "running" && at.Sub(v.UpdatedAt.Time) >= config.BackfillStall {
			stalled++
		}
	}
	for _, v := range input.AttentionBackfills {
		if v.Status == "failed" {
			failed++
		}
	}
	appendRule(stalled > 0, "backfill_without_progress", "backfill:without_progress", "critical", "A running backfill has not reported progress within the configured threshold.", "running-and-validating-backfills", map[string]string{"backfill_count": strconv.Itoa(stalled)})
	appendRule(failed > 0, "terminal_backfill_failure", "backfill:terminal_failure", "critical", "A backfill ended in a terminal failure.", "running-and-validating-backfills", map[string]string{"backfill_count": strconv.Itoa(failed)})
	for _, mode := range []bool{false, true} {
		total, bad := 0.0, 0.0
		items := input.Results
		rule, key, summary, threshold, minimum := "index_failure_ratio", "ingestion:index_failure_ratio", "The measured ingestion failure ratio is above threshold.", config.IndexFailureRatio, config.IndexFailureMinimum
		if mode {
			items = input.Requests
			rule = "appview_5xx_ratio"
			key = "appview:http_5xx_ratio"
			summary = "The measured AppView HTTP 5xx ratio is above threshold."
			threshold = config.AppView5xxRatio
			minimum = config.AppView5xxMinimumRequests
		}
		for _, v := range items {
			if mode && v.Dimensions["service"] != "appview" {
				continue
			}
			if math.IsNaN(v.ValueSum) || math.IsInf(v.ValueSum, 0) {
				continue
			}
			total += v.ValueSum
			if !mode && v.Dimensions["result"] == "error" || mode && v.Dimensions["status_class"] == "5xx" {
				bad += v.ValueSum
			}
		}
		ratio := 0.0
		if total > 0 {
			ratio = bad / total
		}
		appendRule(total >= float64(minimum) && ratio >= threshold, rule, key, "critical", summary, "live-process-stalled-ingestion", map[string]string{"sample_count": fmt.Sprint(total), "failure_ratio": fmt.Sprint(ratio), "threshold": fmt.Sprint(threshold)})
	}
	return rules
}
func optionalInt64(v *int64, fallback string) string {
	if v == nil {
		return fallback
	}
	return strconv.FormatInt(*v, 10)
}
func (e AlertEvaluator) Evaluate(ctx context.Context, at time.Time) error {
	input := AlertEvaluationInput{}
	var err error
	input.Services, err = e.Store.ListServiceStates(ctx)
	if err != nil {
		return err
	}
	input.Streams, err = e.Store.ListStreamStates(ctx)
	if err != nil {
		return err
	}
	d, err := e.Store.FetchIngestionDurabilitySnapshot(ctx, at)
	if err == nil {
		input.Durability = &d
	}
	input.Counts, err = e.Store.LifecycleCounts(ctx)
	if err != nil {
		return err
	}
	active, err := e.Store.ListBackfills(ctx, "active", 250, nil)
	if err != nil {
		return err
	}
	attention, err := e.Store.ListBackfills(ctx, "attention", 250, nil)
	if err != nil {
		return err
	}
	input.ActiveBackfills = active.Items
	input.AttentionBackfills = attention.Items
	start, end := at.Add(-5*time.Minute), at.Truncate(time.Minute).Add(-time.Millisecond)
	input.Results, err = e.Store.ListMetricRollups(ctx, start, end, pointer("socialwire.ingestion.results_total"), nil, 10000)
	if err != nil {
		return err
	}
	input.Requests, err = e.Store.ListMetricRollups(ctx, start, end, pointer("socialwire.http.server.requests_total"), nil, 10000)
	if err != nil {
		return err
	}
	for _, rule := range EvaluateAlertConditions(input, e.Config, at) {
		if rule.Active {
			_, err = e.Store.OpenAlert(ctx, rule.Rule, rule.Key, rule.Severity, rule.Summary, rule.Evidence, rule.Runbook, at)
		} else {
			err = e.Store.ResolveAlert(ctx, rule.Key, at)
		}
		if err != nil {
			return err
		}
	}
	if !e.Config.AlertDeliveryEnabled || e.Webhook == nil {
		return nil
	}
	due, err := e.Store.ListAlertsPendingDelivery(ctx, 100, at)
	if err != nil {
		return err
	}
	for _, alert := range due {
		var failure *string
		if err = e.Webhook.Deliver(ctx, alert); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			failure = pointer("webhook_delivery_failed")
		}
		if err = e.Store.RecordAlertDelivery(ctx, alert.ID, failure, at); err != nil {
			return err
		}
	}
	return nil
}

type AlertEvaluator struct {
	Store   *PostgresStore
	Config  Config
	Webhook *WebhookDelivery
}
