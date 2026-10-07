package operationsapi

type BackfillAuthorResult struct {
	DID             string  `json:"did"`
	Collection      string  `json:"collection"`
	DiscoveredCount int     `json:"discoveredCount"`
	ProcessedCount  int     `json:"processedCount"`
	FailedCount     int     `json:"failedCount"`
	Capped          bool    `json:"capped"`
	Truncated       bool    `json:"truncated"`
	Status          string  `json:"status"`
	Error           *string `json:"error,omitempty"`
}
