package operationsapi

type WorkerCommand struct {
	ID             string    `json:"id"`
	Environment    string    `json:"environment"`
	Action         string    `json:"action"`
	Status         string    `json:"status"`
	RequestedByDID string    `json:"requestedByDid"`
	AuditNote      *string   `json:"auditNote,omitempty"`
	ClaimedBy      *string   `json:"claimedBy,omitempty"`
	LeaseExpiresAt *WireTime `json:"leaseExpiresAt,omitempty"`
	FailureReason  *string   `json:"failureReason,omitempty"`
	CreatedAt      WireTime  `json:"createdAt"`
	UpdatedAt      WireTime  `json:"updatedAt"`
	CompletedAt    *WireTime `json:"completedAt,omitempty"`
	Version        int       `json:"version"`
}
