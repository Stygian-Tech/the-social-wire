package operationsapi

type TraceSpan struct {
	ID           string            `json:"id"`
	Environment  string            `json:"environment"`
	TraceID      string            `json:"traceId"`
	ParentSpanID *string           `json:"parentSpanId,omitempty"`
	Service      string            `json:"service"`
	Name         string            `json:"name"`
	StartedAt    WireTime          `json:"startedAt"`
	DurationMS   float64           `json:"durationMs"`
	Status       string            `json:"status"`
	Attributes   map[string]string `json:"attributes"`
	ExpiresAt    WireTime          `json:"expiresAt"`
}
