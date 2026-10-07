package operationsapi

type CreateBackfillRequest struct {
	DryRun                  BackfillDryRunRequest `json:"dryRun"`
	ExpectedEstimate        int                   `json:"expectedEstimate"`
	AuditNote               *string               `json:"auditNote,omitempty"`
	EnvironmentConfirmation *string               `json:"environmentConfirmation,omitempty"`
	IdempotencyKey          string                `json:"idempotencyKey"`
	ExpectedGapVersion      *int                  `json:"expectedGapVersion,omitempty"`
	RequestFingerprint      string                `json:"requestFingerprint"`
}
