package operationsapi

import (
	"context"
	"maps"
	"sort"
	"strconv"
	"strings"
	"time"
)

type EvidenceMonitor struct {
	Store             *PostgresStore
	serviceSignatures map[string]string
	serviceEmittedAt  map[string]time.Time
	streamVersions    map[string]int
	capabilityPayload map[string]string
}

func sortedDependencies(values map[string]string) string {
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, k+"="+values[k])
	}
	return strings.Join(pairs, ";")
}
func (m *EvidenceMonitor) Observe(ctx context.Context, at time.Time) error {
	services, e := m.Store.ListServiceStates(ctx)
	if e != nil {
		return e
	}
	streams, e := m.Store.ListStreamStates(ctx)
	if e != nil {
		return e
	}
	if m.serviceSignatures == nil {
		m.serviceSignatures = map[string]string{}
		m.serviceEmittedAt = map[string]time.Time{}
		m.streamVersions = map[string]int{}
	}
	live := map[string]bool{}
	for _, s := range services {
		live[s.Service+":"+s.InstanceID] = true
	}
	expired := []string{}
	for k := range m.serviceSignatures {
		if !live[k] {
			expired = append(expired, k)
		}
	}
	sort.Strings(expired)
	for _, key := range expired {
		if _, e = m.Store.AppendChangeEvent(ctx, ChangeEvent{EventType: "service.expired", EntityType: "service", EntityID: &key, Payload: map[string]string{"accuracy": "unavailable", "reason": "heartbeat_expired"}, OccurredAt: at}); e != nil {
			return e
		}
		delete(m.serviceSignatures, key)
		delete(m.serviceEmittedAt, key)
	}
	for _, s := range services {
		key := s.Service + ":" + s.InstanceID
		deps := sortedDependencies(s.DependencyState)
		signature := strings.Join([]string{s.Liveness, s.Readiness, s.Freshness, s.Completeness, deps}, "|")
		if m.serviceSignatures[key] == signature && at.Sub(m.serviceEmittedAt[key]) < 30*time.Second {
			continue
		}
		if _, e = m.Store.AppendChangeEvent(ctx, ChangeEvent{EventType: "service.update", EntityType: "service", EntityID: &key, Payload: map[string]string{"liveness": s.Liveness, "readiness": s.Readiness, "freshness": s.Freshness, "completeness": s.Completeness, "heartbeatAt": s.HeartbeatAt.UTC().Format(time.RFC3339), "dependencies": deps}, OccurredAt: at}); e != nil {
			return e
		}
		m.serviceSignatures[key] = signature
		m.serviceEmittedAt[key] = at
	}
	for _, s := range streams {
		if v, ok := m.streamVersions[s.Source]; ok && v == s.Version {
			continue
		}
		payload := map[string]string{"connectionState": s.ConnectionState, "version": strconv.Itoa(s.Version), "heartbeatAt": s.HeartbeatAt.UTC().Format(time.RFC3339), "transportHeartbeatAt": formatOptionalTime(s.TransportHeartbeatAt, ""), "lastIndexedMutationAt": formatOptionalTime(s.LastIndexedMutationAt, ""), "projectionWatermark": optionalString(s.ProjectionWatermark, ""), "validationWatermark": optionalString(s.ValidationWatermark, "")}
		if _, e = m.Store.AppendChangeEvent(ctx, ChangeEvent{EventType: "ingestion.update", EntityType: "ingestion", EntityID: &s.Source, Payload: payload, OccurredAt: at}); e != nil {
			return e
		}
		m.streamVersions[s.Source] = s.Version
	}
	return nil
}
func (m *EvidenceMonitor) ObserveCapabilities(ctx context.Context, config Config, at time.Time) error {
	c := ResolveCapabilities(ctx, m.Store, config, at)
	payload := map[string]string{"telemetry": strconv.FormatBool(c.Telemetry.Enabled), "recovery": strconv.FormatBool(c.Recovery.Enabled), "tapVerifiedResync": strconv.FormatBool(c.RecoveryModes.TapVerifiedResync.Enabled), "jetstreamReplay": strconv.FormatBool(c.RecoveryModes.JetstreamReplay.Enabled), "pdsReconciliation": strconv.FormatBool(c.RecoveryModes.PDSReconciliation.Enabled), "alertDelivery": strconv.FormatBool(c.AlertDelivery.Enabled), "eventStream": strconv.FormatBool(c.EventStream.Enabled)}
	if maps.Equal(payload, m.capabilityPayload) {
		return nil
	}
	if _, e := m.Store.AppendChangeEvent(ctx, ChangeEvent{EventType: "capability.changed", EntityType: "capability", EntityID: &config.Environment, Payload: payload, OccurredAt: at}); e != nil {
		return e
	}
	m.capabilityPayload = payload
	return nil
}
func formatOptionalTime(t *WireTime, fallback string) string {
	if t == nil {
		return fallback
	}
	return t.UTC().Format(time.RFC3339)
}
func optionalString(v *string, fallback string) string {
	if v == nil {
		return fallback
	}
	return *v
}
