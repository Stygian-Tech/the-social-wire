package operationsapi

import (
	"strconv"
	"strings"
	"time"
)

const DurableJetstreamV2AuthoritySource = "jetstream_v2_inbox"

type IngestionAuthorityResolution struct {
	Source            *string
	State             *StreamState
	DurableCheckpoint *DurabilityCheckpoint
	DurableInbox      *InboxMetrics
	Evidence          EvidenceMetadata
}

func pointer[T any](value T) *T { return &value }
func activeCoordinator(states []ServiceState, at time.Time, validity time.Duration) *ServiceState {
	active := []ServiceState{}
	for _, state := range states {
		if state.DependencyState["coordinator_authority"] == "active" && state.DependencyState["coordinator_role"] == "indexing.appview-coordinator" {
			active = append(active, state)
		}
	}
	return freshWorker("coordinator-appview", active, at, validity)
}
func IngestionWorker(states []ServiceState, at time.Time) *ServiceState {
	service := "appview-worker"
	for _, state := range states {
		if state.Service == "projection-pool-appview" {
			service = state.Service
			break
		}
	}
	return freshWorker(service, states, at, 15*time.Second)
}
func requiredWorkerStates(states []ServiceState, at time.Time, validity time.Duration) []ServiceState {
	projection, coordinator := freshWorker("projection-pool-appview", states, at, validity), activeCoordinator(states, at, validity)
	if projection != nil && coordinator != nil {
		return []ServiceState{*projection, *coordinator}
	}
	for _, state := range states {
		if state.Service == "projection-pool-appview" || state.Service == "coordinator-appview" {
			return []ServiceState{}
		}
	}
	if worker := freshWorker("appview-worker", states, at, validity); worker != nil {
		return []ServiceState{*worker}
	}
	return []ServiceState{}
}
func ServiceEvidence(states []ServiceState, at time.Time) EvidenceMetadata {
	return ServiceEvidenceFor(states, []string{"gateway", "appview", "appview-worker", "operations"}, "operations_service_state", at, 45*time.Second)
}
func ServiceEvidenceFor(states []ServiceState, required []string, source string, at time.Time, validity time.Duration) EvidenceMetadata {
	missing := []string{}
	freshCount := 0
	var watermark *WireTime
	for _, name := range required {
		group := []ServiceState{}
		if name == "appview-worker" {
			group = requiredWorkerStates(states, at, validity)
		} else {
			var latest *ServiceState
			for _, state := range states {
				if state.Service == name && (latest == nil || state.HeartbeatAt.After(latest.HeartbeatAt)) {
					copy := state
					latest = &copy
				}
			}
			if latest != nil {
				group = append(group, *latest)
			}
		}
		fresh := len(group) > 0
		for _, state := range group {
			age := at.Sub(state.HeartbeatAt)
			fresh = fresh && age >= -time.Second && age <= validity
			if watermark == nil || state.HeartbeatAt.Before(watermark.Time) {
				watermark = &WireTime{state.HeartbeatAt}
			}
		}
		if fresh {
			freshCount++
		} else {
			missing = append(missing, name)
		}
	}
	accuracy := "sampled"
	if freshCount == 0 {
		accuracy = "unavailable"
	} else if len(missing) == 0 {
		accuracy = "exact"
	}
	e := EvidenceMetadata{Source: source, Accuracy: accuracy, GeneratedAt: WireTime{at}, IndexedThrough: watermark, ValidUntil: WireTime{at}, Coverage: pointer(evidenceCoverage(freshCount, len(required))), LastSuccessfulAt: watermark}
	if watermark != nil {
		e.AgeSeconds = max(0, at.Sub(watermark.Time).Seconds())
		e.ValidUntil = WireTime{watermark.Add(validity)}
	}
	if len(missing) > 0 {
		e.DegradedReason = pointer("Missing or expired required service evidence: " + strings.Join(missing, ", ") + ".")
	}
	return e
}
func ResolveIngestionAuthority(services []ServiceState, streams []StreamState, durability *DurabilitySnapshot, at time.Time) IngestionAuthorityResolution {
	worker := IngestionWorker(services, at)
	var source *string
	if worker != nil {
		advertised := worker.DependencyState["ingestion_authority"]
		if advertised == "jetstream" || advertised == "tap" || advertised == DurableJetstreamV2AuthoritySource {
			source = &advertised
		}
	}
	if source != nil && *source == DurableJetstreamV2AuthoritySource {
		return resolveDurableAuthority(worker, durability, at)
	}
	var state *StreamState
	if source != nil {
		for _, candidate := range streams {
			if candidate.Source == *source {
				copy := candidate
				state = &copy
				break
			}
		}
	}
	var heartbeat *WireTime
	if state != nil {
		heartbeat = state.TransportHeartbeatAt
	}
	fresh := heartbeat != nil && at.Sub(heartbeat.Time) <= 45*time.Second
	var reason *string
	if source == nil {
		reason = pointer("No fresh ingestion-authority capability evidence is available.")
	} else if heartbeat == nil {
		reason = pointer("No transport heartbeat exists for the authoritative ingestion source.")
	} else if !fresh {
		reason = pointer("The authoritative ingestion transport heartbeat has expired.")
	}
	accuracy := "unavailable"
	coverage := 0.0
	if fresh {
		accuracy = "exact"
		coverage = 1
	}
	e := EvidenceMetadata{Source: "appview_ingestion_stream_state", Accuracy: accuracy, GeneratedAt: WireTime{at}, IndexedThrough: heartbeat, ValidUntil: WireTime{at}, Coverage: &coverage, LastSuccessfulAt: heartbeat, DegradedReason: reason}
	if heartbeat != nil {
		e.AgeSeconds = max(0, at.Sub(heartbeat.Time).Seconds())
		e.ValidUntil = WireTime{heartbeat.Add(45 * time.Second)}
	}
	return IngestionAuthorityResolution{Source: source, State: state, Evidence: e}
}
func resolveDurableAuthority(worker *ServiceState, durability *DurabilitySnapshot, at time.Time) IngestionAuthorityResolution {
	source := DurableJetstreamV2AuthoritySource
	generation := ""
	if worker != nil {
		generation = worker.DependencyState["jetstream_v2_source_generation"]
	}
	var checkpoint *DurabilityCheckpoint
	var inbox *InboxMetrics
	if generation != "" && durability != nil {
		value := durability.InboxBySourceGeneration[generation]
		inbox = &value
		for _, candidate := range durability.Checkpoints {
			if candidate.Environment == worker.Environment && candidate.SourceGeneration == generation && candidate.CursorKind == "jetstream_v2_seq" {
				copy := candidate
				checkpoint = &copy
				break
			}
		}
	}
	terminal := checkpoint != nil && checkpoint.ReplayState == "snapshot_complete"
	var observed *WireTime
	if checkpoint != nil {
		observed = checkpoint.IntakeHeartbeatAt
		if terminal {
			observed = &checkpoint.UpdatedAt
		}
	}
	fresh := terminal || observed != nil && at.Sub(observed.Time) >= 0 && at.Sub(observed.Time) <= 45*time.Second
	var reason *string
	switch {
	case generation == "":
		reason = pointer("The durable Jetstream V2 source generation is not advertised.")
	case durability == nil:
		reason = pointer("Durable Jetstream V2 checkpoint evidence is unavailable.")
	case checkpoint == nil:
		reason = pointer("No matching durable Jetstream V2 checkpoint exists for the advertised source generation.")
	case observed == nil:
		reason = pointer("No active fenced Jetstream V2 intake lease exists for the advertised source generation.")
	case !fresh:
		reason = pointer("The fenced Jetstream V2 intake lease heartbeat has expired.")
	}
	accuracy := "unavailable"
	coverage := 0.0
	validUntil := at
	if observed != nil {
		validUntil = observed.Add(45 * time.Second)
	}
	if terminal {
		validUntil = time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	e := EvidenceMetadata{Source: "appview_jetstream_checkpoints", Accuracy: accuracy, GeneratedAt: WireTime{at}, ValidUntil: WireTime{validUntil}, Coverage: &coverage, LastSuccessfulAt: observed, DegradedReason: reason}
	if fresh {
		e.Accuracy = "exact"
		*e.Coverage = 1
		e.IndexedThrough = observed
		if observed != nil {
			e.AgeSeconds = max(0, at.Sub(observed.Time).Seconds())
		}
	}
	var state *StreamState
	if checkpoint != nil {
		counts := InboxMetrics{}
		if inbox != nil {
			counts = *inbox
		}
		sampled := at
		if durability != nil {
			sampled = durability.GeneratedAt.Time
		}
		value := durableAuthorityState(*checkpoint, counts, sampled)
		state = &value
	}
	return IngestionAuthorityResolution{Source: &source, State: state, DurableCheckpoint: checkpoint, DurableInbox: inbox, Evidence: e}
}
func durableAuthorityState(checkpoint DurabilityCheckpoint, inbox InboxMetrics, observed time.Time) StreamState {
	connection := "connected"
	var reason *string
	var disconnect *WireTime
	if checkpoint.ReplayState == "failed" {
		connection = "disconnected"
		reason = pointer("durable_replay_failed")
		disconnect = &checkpoint.UpdatedAt
	} else if checkpoint.ReplayState == "paused_budget" {
		connection = "reconnecting"
		reason = pointer("replay_budget_paused")
	}
	stamp := WireTime{observed}
	queue := &EvidenceMetadata{Source: "appview_ingestion_inbox", Accuracy: "exact", GeneratedAt: stamp, IndexedThrough: &stamp, ValidUntil: WireTime{observed.Add(45 * time.Second)}, Coverage: pointer(1.0), LastSuccessfulAt: &stamp}
	heartbeat := checkpoint.UpdatedAt
	if checkpoint.IntakeHeartbeatAt != nil {
		heartbeat = *checkpoint.IntakeHeartbeatAt
	}
	state := StreamState{Environment: checkpoint.Environment, Source: DurableJetstreamV2AuthoritySource, ConnectionState: connection, LastDisconnectAt: disconnect, LastDisconnectReason: reason, LastReceivedCursor: checkpoint.LastStagedSequence, LastReceivedEventAt: checkpoint.LastStagedEventAt, LastReceivedAt: checkpoint.LastStagedAt, LastCommittedCursor: checkpoint.LastAppliedSequence, LastCommittedEventAt: checkpoint.LastAppliedEventAt, LastCommittedAt: checkpoint.LastAppliedAt, QueueDepth: inbox.Pending + inbox.Leased + inbox.Retrying, QueueEvidence: queue, TransportHeartbeatAt: checkpoint.IntakeHeartbeatAt, LastIndexedMutationAt: checkpoint.LastAppliedAt, ValidationWatermark: checkpoint.LastReconciledRepositoryRevision, HeartbeatAt: heartbeat}
	if checkpoint.LastAppliedSequence != nil {
		state.ProjectionWatermark = pointer(strconv.FormatInt(*checkpoint.LastAppliedSequence, 10))
	}
	return state
}

func evidenceCoverage(count, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(count) / float64(total)
}
