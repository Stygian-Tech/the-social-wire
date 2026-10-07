package operationsapi

import (
	"context"
	"sync"
	"time"
)

type Overview struct {
	Services           []ServiceState                 `json:"services"`
	Ingestion          *StreamState                   `json:"ingestion,omitempty"`
	IngestionSources   []StreamState                  `json:"ingestionSources"`
	JetstreamEndpoints []EndpointState                `json:"jetstreamEndpoints"`
	Commands           []WorkerCommand                `json:"commands"`
	Gaps               []Gap                          `json:"gaps"`
	Backfills          []BackfillJob                  `json:"backfills"`
	Alerts             []Alert                        `json:"alerts"`
	RecentTraces       []TraceSpan                    `json:"recentTraces"`
	MetricRollups      []MetricRollup                 `json:"metricRollups"`
	Database           *DatabaseObservabilitySnapshot `json:"database,omitempty"`
	RefreshedAt        WireTime                       `json:"refreshedAt"`
	Evidence           map[string]EvidenceMetadata    `json:"evidence"`
	Capabilities       *Capabilities                  `json:"capabilities,omitempty"`
	Counts             LifecycleCounts                `json:"counts"`
	Viewers            *ViewerCounts                  `json:"viewers,omitempty"`
	ViewerHistory      []ViewerCounts                 `json:"viewerHistory"`
	Durability         *DurabilitySnapshot            `json:"durability,omitempty"`
}

func (s *PostgresStore) Overview(ctx context.Context, at time.Time, capabilities *Capabilities) (Overview, error) {
	var services []ServiceState
	var streams []StreamState
	var counts LifecycleCounts
	var viewers *ViewerCounts
	history := []ViewerCounts{}
	var durability *DurabilitySnapshot
	var servicesErr, streamsErr, countsErr error
	var wg sync.WaitGroup
	tasks := []func(){func() { services, servicesErr = s.ListServiceStates(ctx) }, func() { streams, streamsErr = s.ListStreamStates(ctx) }, func() { counts, countsErr = s.LifecycleCounts(ctx) }, func() {
		value, err := s.FetchViewerCounts(ctx, at)
		if err == nil {
			viewers = value
		}
	}, func() {
		value, err := s.FetchViewerHistory(ctx, at)
		if err == nil {
			history = value
		}
	}, func() {
		value, err := s.FetchIngestionDurabilitySnapshot(ctx, at)
		if err == nil {
			durability = &value
		}
	}}
	for _, task := range tasks {
		wg.Add(1)
		go func() { defer wg.Done(); task() }()
	}
	database := s.FetchDatabaseObservability(ctx, at)
	wg.Wait()
	for _, err := range []error{servicesErr, streamsErr, countsErr, ctx.Err()} {
		if err != nil {
			return Overview{}, err
		}
	}
	authority := ResolveIngestionAuthority(services, streams, durability, at)
	databaseEvidence := EvidenceMetadata{Source: "pg_stat_database", Accuracy: "unavailable", GeneratedAt: WireTime{at}, ValidUntil: WireTime{at}, Coverage: pointer(0.0), DegradedReason: pointer("Database observability query failed.")}
	if database != nil {
		databaseEvidence.Accuracy = "estimated"
		databaseEvidence.IndexedThrough = &database.ObservedAt
		databaseEvidence.AgeSeconds = max(0, at.Sub(database.ObservedAt.Time).Seconds())
		databaseEvidence.ValidUntil = WireTime{database.ObservedAt.Add(time.Minute)}
		databaseEvidence.Coverage = pointer(1.0)
		databaseEvidence.LastSuccessfulAt = &database.ObservedAt
		databaseEvidence.DegradedReason = nil
	}
	return Overview{Services: services, Ingestion: authority.State, IngestionSources: streams, JetstreamEndpoints: []EndpointState{}, Commands: []WorkerCommand{}, Gaps: []Gap{}, Backfills: []BackfillJob{}, Alerts: []Alert{}, RecentTraces: []TraceSpan{}, MetricRollups: []MetricRollup{}, Database: database, RefreshedAt: WireTime{at}, Evidence: map[string]EvidenceMetadata{"services": ServiceEvidence(services, at), "ingestion": authority.Evidence, "database": databaseEvidence}, Capabilities: capabilities, Counts: counts, Viewers: viewers, ViewerHistory: history, Durability: durability}, nil
}
