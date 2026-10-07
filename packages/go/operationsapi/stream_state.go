package operationsapi

type StreamState struct {
	Environment           string            `json:"environment"`
	Source                string            `json:"source"`
	ConnectionState       string            `json:"connectionState"`
	ConnectedAt           *WireTime         `json:"connectedAt,omitempty"`
	LastDisconnectAt      *WireTime         `json:"lastDisconnectAt,omitempty"`
	LastDisconnectReason  *string           `json:"lastDisconnectReason,omitempty"`
	LastReceivedCursor    *int64            `json:"lastReceivedCursor,omitempty"`
	LastReceivedEventAt   *WireTime         `json:"lastReceivedEventAt,omitempty"`
	LastReceivedAt        *WireTime         `json:"lastReceivedAt,omitempty"`
	LastCommittedCursor   *int64            `json:"lastCommittedCursor,omitempty"`
	LastCommittedEventAt  *WireTime         `json:"lastCommittedEventAt,omitempty"`
	LastCommittedAt       *WireTime         `json:"lastCommittedAt,omitempty"`
	QueueDepth            int               `json:"queueDepth"`
	QueueCapacity         *int              `json:"queueCapacity,omitempty"`
	QueueOverflowTotal    *int64            `json:"queueOverflowTotal,omitempty"`
	QueueEvidence         *EvidenceMetadata `json:"queueEvidence,omitempty"`
	TransportHeartbeatAt  *WireTime         `json:"transportHeartbeatAt,omitempty"`
	LastIndexedMutationAt *WireTime         `json:"lastIndexedMutationAt,omitempty"`
	ProjectionWatermark   *string           `json:"projectionWatermark,omitempty"`
	ValidationWatermark   *string           `json:"validationWatermark,omitempty"`
	HeartbeatAt           WireTime          `json:"heartbeatAt"`
	Version               int               `json:"version"`
}
