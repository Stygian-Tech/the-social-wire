package operationsapi

type EvidenceMetadata struct {
	Source           string    `json:"source"`
	Accuracy         string    `json:"accuracy"`
	GeneratedAt      WireTime  `json:"generatedAt"`
	IndexedThrough   *WireTime `json:"indexedThrough,omitempty"`
	AgeSeconds       float64   `json:"ageSeconds"`
	ValidUntil       WireTime  `json:"validUntil"`
	Coverage         *float64  `json:"coverage,omitempty"`
	LastSuccessfulAt *WireTime `json:"lastSuccessfulAt,omitempty"`
	DegradedReason   *string   `json:"degradedReason,omitempty"`
}
