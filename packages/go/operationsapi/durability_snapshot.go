package operationsapi

type DurabilitySnapshot struct {
	Environment               string                  `json:"environment"`
	Checkpoints               []DurabilityCheckpoint  `json:"checkpoints"`
	Inbox                     InboxMetrics            `json:"inbox"`
	InboxBySourceGeneration   map[string]InboxMetrics `json:"inboxBySourceGeneration"`
	Incidents                 IncidentMetrics         `json:"incidents"`
	ReplayBytesRolling24Hours int64                   `json:"replayBytesRolling24Hours"`
	GeneratedAt               WireTime                `json:"generatedAt"`
}
