package operationsapi

type GapCauseAssessment struct {
	Title       string   `json:"title"`
	Confidence  string   `json:"confidence"`
	Summary     string   `json:"summary"`
	EvidenceIDs []string `json:"evidenceIds"`
	Limitations []string `json:"limitations"`
}
