package operationsapi

type BackfillJob struct {
	ID                  string                 `json:"id"`
	Environment         string                 `json:"environment"`
	GapID               *string                `json:"gapId,omitempty"`
	SourceMode          string                 `json:"sourceMode"`
	Status              string                 `json:"status"`
	StartCursor         *int64                 `json:"startCursor,omitempty"`
	EndCursor           *int64                 `json:"endCursor,omitempty"`
	CheckpointCursor    *int64                 `json:"checkpointCursor,omitempty"`
	Collections         []string               `json:"collections"`
	AuthorDIDs          []string               `json:"authorDids"`
	AuthorResults       []BackfillAuthorResult `json:"authorResults"`
	BatchSize           int                    `json:"batchSize"`
	RateLimit           int                    `json:"rateLimit"`
	MaxConcurrency      int                    `json:"maxConcurrency"`
	EstimatedCount      int                    `json:"estimatedCount"`
	ProcessedCount      int                    `json:"processedCount"`
	FailedCount         int                    `json:"failedCount"`
	ReconciledCount     int                    `json:"reconciledCount"`
	RequestedByDID      string                 `json:"requestedByDid"`
	AuditNote           *string                `json:"auditNote,omitempty"`
	FailureReason       *string                `json:"failureReason,omitempty"`
	LeaseOwner          *string                `json:"leaseOwner,omitempty"`
	LeaseExpiresAt      *WireTime              `json:"leaseExpiresAt,omitempty"`
	CreatedAt           WireTime               `json:"createdAt"`
	UpdatedAt           WireTime               `json:"updatedAt"`
	CompletedAt         *WireTime              `json:"completedAt,omitempty"`
	Version             int                    `json:"version"`
	VerificationStatus  string                 `json:"verificationStatus"`
	VerificationReason  *string                `json:"verificationReason,omitempty"`
	ScopeTruncated      bool                   `json:"scopeTruncated"`
	ValidationWatermark *string                `json:"validationWatermark,omitempty"`
}
