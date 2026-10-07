package operationsapi

type LifecycleCounts struct {
	ActiveGaps         int `json:"activeGaps"`
	ActiveBackfills    int `json:"activeBackfills"`
	AttentionBackfills int `json:"attentionBackfills"`
	CompletedBackfills int `json:"completedBackfills"`
	UnresolvedAlerts   int `json:"unresolvedAlerts"`
}
