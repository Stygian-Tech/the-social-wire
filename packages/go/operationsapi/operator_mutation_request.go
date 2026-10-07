package operationsapi

type OperatorMutationRequest struct {
	ID                      *string `json:"id,omitempty"`
	Status                  string  `json:"status,omitempty"`
	AuditNote               *string `json:"auditNote,omitempty"`
	EnvironmentConfirmation *string `json:"environmentConfirmation,omitempty"`
	IdempotencyKey          string  `json:"idempotencyKey"`
	ExpectedVersion         *int    `json:"expectedVersion"`
}
