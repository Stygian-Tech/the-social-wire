package operationsapi

type GapInvestigationEvidence struct {
	ID         string            `json:"id"`
	Kind       string            `json:"kind"`
	OccurredAt WireTime          `json:"occurredAt"`
	Service    string            `json:"service"`
	Title      string            `json:"title"`
	Detail     string            `json:"detail"`
	Attributes map[string]string `json:"attributes"`
	TraceID    *string           `json:"traceId,omitempty"`
}
