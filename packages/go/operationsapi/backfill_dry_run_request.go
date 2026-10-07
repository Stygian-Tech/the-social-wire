package operationsapi

type BackfillDryRunRequest struct {
	GapID          *string  `json:"gapId,omitempty"`
	SourceMode     string   `json:"sourceMode"`
	StartCursor    *int64   `json:"startCursor,omitempty"`
	EndCursor      *int64   `json:"endCursor,omitempty"`
	Collections    []string `json:"collections"`
	AuthorDIDs     []string `json:"authorDids"`
	BatchSize      int      `json:"batchSize"`
	RateLimit      int      `json:"rateLimit"`
	MaxConcurrency int      `json:"maxConcurrency"`
}
