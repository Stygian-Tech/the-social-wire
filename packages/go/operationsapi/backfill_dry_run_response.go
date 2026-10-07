package operationsapi

type BackfillDryRunResponse struct {
	EstimatedCount           int                          `json:"estimatedCount"`
	EstimatedDurationSeconds int                          `json:"estimatedDurationSeconds"`
	SnapshotEndCursor        *int64                       `json:"snapshotEndCursor,omitempty"`
	Conflicts                []string                     `json:"conflicts"`
	UnresolvedDeletesWarning bool                         `json:"unresolvedDeletesWarning"`
	RequestFingerprint       string                       `json:"requestFingerprint"`
	ValidUntil               WireTime                     `json:"validUntil"`
	Methodology              string                       `json:"methodology"`
	Confidence               string                       `json:"confidence"`
	EstimateKind             string                       `json:"estimateKind"`
	Uncertainty              *BackfillEstimateUncertainty `json:"uncertainty,omitempty"`
}
