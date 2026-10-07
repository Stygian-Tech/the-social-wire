package operationsapi

import (
	"context"
	"fmt"
	"time"
)

type Capability struct {
	Enabled        bool    `json:"enabled"`
	DisabledReason *string `json:"disabledReason,omitempty"`
}

func capability(enabled bool, reason string) Capability {
	c := Capability{Enabled: enabled}
	if !enabled && reason != "" {
		c.DisabledReason = &reason
	}
	return c
}

type RecoveryModeCapabilities struct {
	TapVerifiedResync Capability `json:"tapVerifiedResync"`
	JetstreamReplay   Capability `json:"jetstreamReplay"`
	PDSReconciliation Capability `json:"pdsReconciliation"`
}
type EventStreamCapability struct {
	Enabled                  bool    `json:"enabled"`
	DisabledReason           *string `json:"disabledReason,omitempty"`
	Path                     string  `json:"path"`
	RetryMilliseconds        int     `json:"retryMilliseconds"`
	FallbackPollMilliseconds int     `json:"fallbackPollMilliseconds"`
}
type Capabilities struct {
	Environment   string                   `json:"environment"`
	Telemetry     Capability               `json:"telemetry"`
	Recovery      Capability               `json:"recovery"`
	RecoveryModes RecoveryModeCapabilities `json:"recoveryModes"`
	AlertDelivery Capability               `json:"alertDelivery"`
	EventStream   EventStreamCapability    `json:"eventStream"`
	GeneratedAt   time.Time                `json:"generatedAt"`
}
type CapabilityStore interface {
	ChangeEventCursorBounds(context.Context) (ChangeEventCursorBounds, error)
	ListServiceStates(context.Context) ([]ServiceState, error)
}

func ResolveCapabilities(ctx context.Context, store CapabilityStore, config Config, now time.Time) Capabilities {
	_, eventErr := store.ChangeEventCursorBounds(ctx)
	states, err := store.ListServiceStates(ctx)
	if err != nil {
		states = nil
	}
	worker := RecoveryWorker(states, now)
	prerequisite := ""
	switch {
	case !config.RecoveryEnabled:
		prerequisite = "Operations recovery is disabled by the environment release gate."
	case config.FingerprintSecret == "":
		prerequisite = "The backfill fingerprint signing secret is unavailable."
	case worker == nil:
		prerequisite = "No active recovery worker capability evidence is available."
	case now.Sub(worker.HeartbeatAt) > 15*time.Second:
		prerequisite = "Recovery worker capability evidence has expired."
	case worker.DependencyState["operations_database"] != "ready" || worker.DependencyState["appview_database"] != "ready":
		prerequisite = "Recovery worker database dependencies are not ready."
	}
	mode := func(key, name string, accepted ...string) Capability {
		if prerequisite != "" {
			return capability(false, prerequisite)
		}
		value, ok := worker.DependencyState[key]
		if !ok {
			return capability(false, "The worker did not advertise "+name+" capability evidence.")
		}
		for _, allowed := range accepted {
			if value == allowed {
				return capability(true, "")
			}
		}
		return capability(false, fmt.Sprintf("%s is unavailable: %s.", name, value))
	}
	jetstream := mode("jetstream_replay", "Jetstream replay", "enabled_unverified", "enabled_durable_v2")
	pds := mode("pds_reconciliation", "PDS reconciliation", "enabled_diagnostic_only")
	recoveryReason := prerequisite
	if recoveryReason == "" {
		recoveryReason = "No worker-advertised recovery mode is currently available."
	}
	alertReady := config.AlertDeliveryEnabled && config.WebhookURL != "" && config.WebhookSecret != ""
	alertReason := ""
	if !config.AlertDeliveryEnabled {
		alertReason = "Alert delivery is disabled by configuration."
	} else if !alertReady {
		alertReason = "Alert delivery webhook configuration is incomplete."
	}
	stream := EventStreamCapability{Enabled: eventErr == nil, Path: "/v1/operations/events/stream", RetryMilliseconds: 1000, FallbackPollMilliseconds: 2500}
	if eventErr != nil {
		reason := "The durable ordered event log is unavailable."
		stream.DisabledReason = &reason
	}
	return Capabilities{Environment: config.Environment, Telemetry: capability(config.Enabled, "Operations telemetry is disabled by configuration."), Recovery: capability(jetstream.Enabled || pds.Enabled, recoveryReason), RecoveryModes: RecoveryModeCapabilities{capability(false, "Tap ingestion is retired; verified resync is unavailable."), jetstream, pds}, AlertDelivery: capability(alertReady, alertReason), EventStream: stream, GeneratedAt: now}
}
