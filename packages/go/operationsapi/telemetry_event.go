package operationsapi

type TelemetryEvent struct {
	ID          string            `json:"id"`
	Service     string            `json:"service"`
	Environment string            `json:"environment"`
	InstanceID  string            `json:"instanceId"`
	Name        string            `json:"name"`
	OccurredAt  WireTime          `json:"occurredAt"`
	RequestID   *string           `json:"requestId,omitempty"`
	TraceID     *string           `json:"traceId,omitempty"`
	Attributes  map[string]string `json:"attributes"`
}
